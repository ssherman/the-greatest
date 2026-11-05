# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # For a mixed book (re-import spec 3.3, 4.3 step 4): every list item or review on it that no CSV row of that
      # user explains was added by hand, so there is no row to say where it belongs. It gets a flagged guess: the
      # book most of the book's rows went to. The same book is written into the mixed verdict as its redirect.
      #
      # Nothing is decided until every row of the book has a current, non-rejected reimport_row verdict, because
      # the destination count is only meaningful over all of them.
      class DecideGuesses
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(mixed_verdict:)
          new(mixed_verdict).call
        end

        def initialize(mixed_verdict)
          @mixed_verdict = mixed_verdict
        end

        def call
          return done(:skipped) unless @mixed_verdict.reimport_mixed? && @mixed_verdict.approved? && @mixed_verdict.superseded_at.nil?
          # An applied verdict is done (deleted, redirect written); only a kept one may still change its mind.
          return done(:skipped) if @mixed_verdict.applied_at.present? && !@mixed_verdict.payload["kept"]

          keys = Array(@mixed_verdict.payload["row_keys"]).map { |import_id, row_number| "reimport:row:#{import_id}:#{row_number}" }
          verdicts = ::Books::RepairVerdict.reimport_row.current.where.not(status: :rejected).where(subject_key: keys).to_a
          return done(:waiting) if verdicts.map(&:subject_key).uniq.size < keys.size
          # Its readers' imports all failed, so no CSV row says where they belong: the book stays as it is. With no
          # entries either, Apply::Mixed deletes it (it needs no redirect).
          return keep_book("no CSV rows") if keys.empty? && entries?

          # A reader is headed to this book (a row of any reader, or a match): it is a real book with real readers,
          # not a lump. Nothing is guessed.
          return keep_book if MixedBooks.headed_to?(book_id)

          destination = most_read(verdicts)
          return done(:waiting) if destination.nil?

          # A superseded keep says the user re-imported that edition later: it explains no entry on this book.
          explained = verdicts.reject { |verdict| verdict.payload["superseded_by"].present? }.map { |verdict| verdict.payload["user_id"] }.to_set
          guesses = unexplained_items(explained).sum { |type, id, user_id| record_guess(type, id, user_id, destination) }
          reopen_if_kept
          @mixed_verdict.update_columns(payload: @mixed_verdict.payload.except("kept", "kept_reason").merge("redirect_to_book_id" => destination))
          done(:decided, guesses: guesses, redirect_to_book_id: destination)
        end

        private

        def book_id = @mixed_verdict.payload["book_id"]

        # Apply closed a kept verdict as a final noop (applied_at set). Without a keep it is a lump again and
        # has to be offered to Apply::Mixed once more.
        def reopen_if_kept
          return unless @mixed_verdict.payload["kept"]

          @mixed_verdict.update_columns(applied_at: nil, payload: @mixed_verdict.payload.except("closed_reason"))
        end

        # Earlier guesses from this book are superseded (not deleted); a later re-decide without a keep brings them
        # back through record_guess's replace_superseded. Applied and rejected guesses stand as they are.
        def entries?
          ::UserListItem.exists?(listable_type: "Books::Book", listable_id: book_id) ||
            ::Review.exists?(reviewable_type: "Books::Book", reviewable_id: book_id)
        end

        def keep_book(reason = "a reader is headed to it")
          ::Books::RepairVerdict.reimport_guess.current.unapplied.where.not(status: :rejected)
            .where("payload->>'from_book_id' = ?", book_id.to_s).update_all(superseded_at: Time.current, updated_at: Time.current)
          @mixed_verdict.update_columns(payload: @mixed_verdict.payload.except("redirect_to_book_id").merge("kept" => true, "kept_reason" => reason))
          done(:kept)
        end

        # Superseded keeps are rows the user re-imported later; they say nothing about where readers went.
        def most_read(verdicts)
          verdicts.reject { |verdict| verdict.payload["superseded_by"].present? }
            .filter_map { |verdict| verdict.payload["to_book_id"] }
            .tally.min_by { |id, count| [-count, id] }&.first
        end

        def unexplained_items(explained)
          items = ::UserListItem.where(listable_type: "Books::Book", listable_id: book_id).joins(:user_list)
            .order(:id).pluck("user_list_items.id", "user_lists.user_id").map { |id, user_id| ["UserListItem", id, user_id] }
          reviews = ::Review.where(reviewable_type: "Books::Book", reviewable_id: book_id)
            .order(:id).pluck(:id, :user_id).map { |id, user_id| ["Review", id, user_id] }
          (items + reviews).reject { |_type, _id, user_id| explained.include?(user_id) }
        end

        def record_guess(type, id, user_id, destination)
          GoodreadsReplay::RecordVerdict.call(
            kind: :reimport_guess, subject_key: "reimport:guess:#{type}:#{id}",
            payload: {item_type: type, item_id: id, user_id: user_id, from_book_id: book_id, to_book_id: destination, guess: true},
            decided_by: :rule, auto: true, replace_superseded: true
          )
          1
        end

        def done(outcome, guesses: 0, redirect_to_book_id: nil)
          Result.new(success?: true, data: {outcome: outcome, guesses: guesses, redirect_to_book_id: redirect_to_book_id}, errors: [])
        end
      end
    end
  end
end
