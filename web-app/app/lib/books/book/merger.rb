module Books
  class Book
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      attr_reader :source_book, :target_book, :stats

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_book = source
        @target_book = target
        @source_book_id = source.id
        @stats = {}
        @affected_ranking_configurations = []
        @transaction_body_completed = false
      end

      # Must not be called from inside a caller-supplied transaction.
      # ActiveRecord::Base.transaction joins an already-open transaction rather
      # than nesting one, so the block below would close without committing and
      # run_post_commit_steps would fire perform_async before the real commit --
      # if the outer transaction then rolled back, a Sidekiq job would wake up
      # describing a merge that never happened.
      def call
        if source_book.id == target_book.id
          return Result.new(
            success?: false,
            data: nil,
            errors: ["Cannot merge a book with itself"]
          )
        end

        ActiveRecord::Base.transaction do
          lock_books
          collect_affected_ranking_configurations
          merge_all_associations
          reconcile_scalars
          target_book.save! if target_book.changed?
          destroy_source_book
          @transaction_body_completed = true
        end

        run_post_commit_steps

        Result.new(success?: true, data: target_book, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        result_for_raised(error, error.message)
      rescue ActiveRecord::RecordNotUnique => error
        result_for_raised(error, "Constraint violation: #{error.message}")
      rescue => error
        result_for_raised(error, error.message)
      end

      private

      # Locks both rows FOR UPDATE before anything moves. Without it two admins
      # merging the same duplicate can both pass the guard above, and the loser's
      # destroy! silently affects zero rows -- books_books has no lock_version, so
      # Rails never checks the affected count -- reporting a completed merge that
      # moved nothing. Ascending id order is what stops two merges with swapped
      # source and target from deadlocking each other. Taking the lock here, before
      # reconcile_scalars dirties target_book, also keeps lock!'s
      # no-unsaved-changes requirement satisfied.
      def lock_books
        [source_book, target_book].sort_by(&:id).each(&:lock!)
      end

      # SearchIndexable's after_commit callbacks -- the target's save! and the
      # source's destroy! -- fire as the transaction block exits, which is AFTER
      # the commit, and Rails propagates anything they raise out of that block
      # straight into the rescues above. Reporting success?: false there would tell
      # the admin a merge failed when the source is already permanently deleted,
      # and their retry would then fail with "not found". So a raise arriving after
      # a successful commit is treated as post-commit fallout.
      #
      # Both halves of merge_committed? are load-bearing. The flag alone would
      # misread a COMMIT that itself failed (a deferred constraint) as success. The
      # missing row alone would misread a merge that never started because a
      # concurrent merge had already consumed the source -- which is precisely what
      # lock_books raises on.
      def result_for_raised(error, message)
        return Result.new(success?: false, data: nil, errors: [message]) unless merge_committed?

        Rails.logger.error(
          "Books::Book::Merger: merge of #{@source_book_id} into #{target_book.id} " \
          "committed, but a commit callback failed: #{error.class}: #{error.message}"
        )
        @stats[:post_commit_error] = error.message
        Result.new(success?: true, data: target_book, errors: [])
      end

      def merge_committed?
        @transaction_body_completed && !::Books::Book.exists?(@source_book_id)
      end

      # Filled in by later tasks.
      def merge_all_associations
      end

      def reconcile_scalars
      end

      def collect_affected_ranking_configurations
      end

      def run_post_commit_steps
      end

      def destroy_source_book
        source_book.destroy!
      end
    end
  end
end
