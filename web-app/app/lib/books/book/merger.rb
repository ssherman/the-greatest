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

      def merge_all_associations
        merge_editions
        merge_external_links
        merge_ai_chats
        merge_images
        merge_identifiers
        merge_book_countries
        merge_series_books
        merge_category_items
        merge_list_items
        merge_user_list_items
        merge_descriptions
        merge_reviews
        merge_book_relationships
        merge_inverse_book_relationships
        repoint_series_representative
      end

      # books_editions has no unique index on book_id, so there is no collision
      # case. MUST run before reconcile_scalars fills default_edition_id, or the
      # survivor's FK points at a row owned by the record about to be deleted.
      def merge_editions
        @stats[:editions] = source_book.editions.update_all(book_id: target_book.id)
      end

      def merge_external_links
        @stats[:external_links] = source_book.external_links.update_all(parent_id: target_book.id)
      end

      def merge_ai_chats
        @stats[:ai_chats] = source_book.ai_chats.update_all(parent_id: target_book.id)
      end

      def merge_images
        has_target_primary = target_book.primary_image.present?
        count = 0

        source_book.images.find_each do |image|
          image.update!(
            parent_id: target_book.id,
            primary: has_target_primary ? false : image.primary
          )
          count += 1
        end

        @stats[:images] = count
      end

      def merge_identifiers
        count = 0
        source_book.identifiers.find_each do |identifier|
          existing = target_book.identifiers.find_by(
            identifier_type: identifier.identifier_type,
            value: identifier.value
          )

          if existing
            identifier.destroy!
          else
            identifier.update!(identifiable_id: target_book.id)
            count += 1
          end
        end
        @stats[:identifiers] = count
      end

      # destroy!, never delete_all: Books::BookCountry declares
      # counter_cache: :book_count on country, and a raw delete leaves
      # books_countries.book_count overcounting permanently.
      def merge_book_countries
        count = 0
        source_book.book_countries.find_each do |link|
          if target_book.book_countries.exists?(country_id: link.country_id)
            link.destroy!
          else
            link.update!(book_id: target_book.id)
            count += 1
          end
        end
        @stats[:book_countries] = count
      end

      def merge_series_books
        count = 0
        source_book.series_books.find_each do |link|
          if target_book.series_books.exists?(series_id: link.series_id)
            link.destroy!
          else
            link.update!(book_id: target_book.id)
            count += 1
          end
        end
        @stats[:series_books] = count
      end

      # Copy-or-skip rather than move: a CategoryItem carries no state worth
      # preserving beyond the link itself, so the source's own row simply dies
      # with it. This is the music pattern.
      def merge_category_items
        count = 0
        source_book.category_items.find_each do |category_item|
          target_book.category_items.find_or_create_by!(category_id: category_item.category_id)
          count += 1
        end
        @stats[:category_items] = count
      end

      def merge_list_items
        count = 0
        source_book.list_items.find_each do |list_item|
          # An auto-generated list's rows belong to the generator, which rewrites
          # them nightly from the underlying user favorites -- and this merge has
          # already moved those. Writing here would raise against the ListItem
          # guard and turn an admin merge into a 500.
          next if list_item.list.auto_generated?

          existing = target_book.list_items.find_by(list_id: list_item.list_id)

          if existing
            existing.update!(verified: true) if list_item.verified? && !existing.verified?
          else
            list_item.update!(listable_id: target_book.id)
          end
          count += 1
        end
        @stats[:list_items] = count
      end

      # position is scoped to the user_list, which does not change, so a moved row
      # keeps a valid position.
      def merge_user_list_items
        count = 0
        source_book.user_list_items.find_each do |entry|
          if UserListItem.exists?(user_list_id: entry.user_list_id, listable: target_book)
            entry.destroy!
          else
            entry.update!(listable_id: target_book.id)
            count += 1
          end
        end
        @stats[:user_list_items] = count
      end

      # Two unique indexes apply: one on
      # (describable, kind, locale, source, source_name) with nulls_not_distinct,
      # and a partial one allowing a single rank=1 row per (describable, kind, locale).
      def merge_descriptions
        preferred_keys = target_book.descriptions.select(&:preferred?)
          .map { |description| [description.kind, description.locale] }
          .to_set
        count = 0

        source_book.descriptions.find_each do |description|
          collides = target_book.descriptions.exists?(
            kind: description.kind,
            locale: description.locale,
            source: description.source,
            source_name: description.source_name
          )

          if collides
            description.destroy!
            next
          end

          attrs = {describable_id: target_book.id}
          if description.preferred? &&
              preferred_keys.include?([description.kind, description.locale])
            attrs[:rank] = :normal
          end

          description.update!(attrs)
          count += 1
        end
        @stats[:descriptions] = count
      end

      # Review has an after_commit :recalculate_summary, so a per-record update!
      # would fire N recalculations. delete_all/update_all skip it and the merger
      # recalculates once, explicitly, inside the transaction.
      #
      # A subquery, not a plucked id list: this codebase has already hit
      # PostgreSQL's 65,535 bind-parameter cap with a large IN.
      def merge_reviews
        dropped = Review.where(reviewable: source_book)
          .where(user_id: Review.where(reviewable: target_book).select(:user_id))
          .delete_all

        moved = Review.where(reviewable: source_book)
          .update_all(reviewable_id: target_book.id)

        @stats[:reviews] = moved
        @stats[:reviews_dropped] = dropped

        Services::Reviews::SummaryRecalculator.recalculate("Books::Book", target_book.id)
      end

      # Repoints book_id. Two rows must be dropped instead: one that already points
      # AT the target (repointing it makes the survivor relate to itself, which
      # no_self_reference rejects and the whole merge would roll back on), and one
      # the target already holds, which the (book_id, related_book_id,
      # relation_type) unique index would reject.
      def merge_book_relationships
        count = 0
        source_book.book_relationships.find_each do |relationship|
          if relationship.related_book_id == target_book.id
            relationship.destroy!
            next
          end

          collides = ::Books::BookRelationship.exists?(
            book_id: target_book.id,
            related_book_id: relationship.related_book_id,
            relation_type: relationship.relation_type
          )

          if collides
            relationship.destroy!
          else
            relationship.update!(book_id: target_book.id)
            count += 1
          end
        end
        @stats[:book_relationships] = count
      end

      # The mirror image: repoints related_book_id, with the same two drops.
      # Direction is meaningful, so a relationship that survives in one direction
      # is not a duplicate of one in the other and both are kept.
      def merge_inverse_book_relationships
        count = 0
        source_book.inverse_book_relationships.find_each do |relationship|
          if relationship.book_id == target_book.id
            relationship.destroy!
            next
          end

          collides = ::Books::BookRelationship.exists?(
            book_id: relationship.book_id,
            related_book_id: target_book.id,
            relation_type: relationship.relation_type
          )

          if collides
            relationship.destroy!
          else
            relationship.update!(related_book_id: target_book.id)
            count += 1
          end
        end
        @stats[:inverse_book_relationships] = count
      end

      # An INBOUND foreign key with on_delete: nullify. Books::Book declares no
      # inverse association for it, so it is queried directly -- and if the merger
      # does nothing, source.destroy! silently blanks the series' representative
      # instead of following the merge.
      def repoint_series_representative
        @stats[:series_representative] = ::Books::Series
          .where(representative_book_id: source_book.id)
          .update_all(representative_book_id: target_book.id)
      end

      # Filled in by later tasks.
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
