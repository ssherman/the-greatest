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

          keys = Array(@mixed_verdict.payload["row_keys"]).map { |import_id, row_number| "reimport:row:#{import_id}:#{row_number}" }
          verdicts = ::Books::RepairVerdict.reimport_row.current.where.not(status: :rejected).where(subject_key: keys).to_a
          return done(:waiting) if verdicts.map(&:subject_key).uniq.size < keys.size

          destination = most_read(verdicts)
          return done(:waiting) if destination.nil?

          explained = verdicts.map { |verdict| verdict.payload["user_id"] }.to_set
          guesses = unexplained_items(explained).sum { |type, id, user_id| record_guess(type, id, user_id, destination) }
          @mixed_verdict.update_columns(payload: @mixed_verdict.payload.merge("redirect_to_book_id" => destination))
          done(:decided, guesses: guesses, redirect_to_book_id: destination)
        end

        private

        def book_id = @mixed_verdict.payload["book_id"]

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
