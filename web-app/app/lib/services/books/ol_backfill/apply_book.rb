# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 1: one book's outcome. Looks the book up, changes its
      # keys, flags pairs, gives its authors keys and writes its log row, all
      # in one transaction. Open Library errors propagate with nothing
      # written; Run retries them and, giving up, calls record_failure.
      class ApplyBook
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        WORK_KEY = "books_work_openlibrary_id"
        DUPLICATE_KEY = "books_work_openlibrary_duplicate_id"

        def self.call(book:, client:, run_id:)
          new(book, client, run_id).call
        end

        # A row that holds a result (anything but failed or unsure) is never
        # overwritten: it may hold the old keys a revert needs.
        REPROCESSABLE = %w[failed unsure].freeze

        def self.record_failure(book:, run_id:, error:)
          ::ActiveRecord::Base.transaction do
            row = ::Books::OpenLibraryBackfill.find_or_initialize_by(book: book)
            row.lock! unless row.new_record?
            next row if settled?(row)

            row.assign_attributes(outcome: :failed, run_id: run_id, error: error.to_s.truncate(1000),
              attempts: row.new_record? ? 1 : row.attempts + 1)
            row.save!
            row
          end
        end

        def self.settled?(row) = row&.persisted? && REPROCESSABLE.exclude?(row.outcome)

        def initialize(book, client, run_id)
          @book = book
          @client = client
          @run_id = run_id
        end

        def call
          return skipped("book #{@book.id} already has a settled row") if self.class.settled?(::Books::OpenLibraryBackfill.find_by(book: @book))

          @inserting = false
          answer = Lookup.call(book: @book, client: @client)
          ::ActiveRecord::Base.transaction do
            row = ::Books::OpenLibraryBackfill.find_or_initialize_by(book: @book)
            row.lock! unless row.new_record?
            # Another run may have settled it during the lookup.
            next skipped("another run settled book #{@book.id} first") if self.class.settled?(row)

            attempts = row.new_record? ? 1 : row.attempts + 1
            @inserting = row.new_record?
            row.assign_attributes(decide(answer).merge(
              lookup: answer.lookup, run_id: @run_id, attempts: attempts, error: nil, confirmed_on_abstain: answer.confirm_only,
              dump_date: answer.source_version&.dig(:dump_date), matcher_version: answer.source_version&.dig(:matcher_version)
            ))
            row.save!
            Result.new(success?: true, data: row, errors: [])
          end
        rescue ::ActiveRecord::RecordNotUnique
          # Only a failed insert of a new backfill row (unique book_id) means another run won; any other
          # uniqueness failure is a real error and must not hide the book.
          raise unless @inserting && ::Books::OpenLibraryBackfill.exists?(book_id: @book.id)

          skipped("another run wrote book #{@book.id} first")
        end

        private

        def skipped(message) = Result.new(success?: false, data: nil, errors: [message])

        def decide(answer)
          stored = stored_keys
          work = answer.work
          return unsure_or_removed(stored, answer.ol_pick) if work.nil?
          # Open Library abstained, but its top answer is a key we hold: nothing to change.
          return unchanged(:confirmed, stored, work.key) if answer.confirm_only

          key = work.key
          other = book_holding(key, work)
          if other
            flag_books(other, key)
            # A book that does not hold the answer takes nothing from it.
            return unchanged(:duplicate_pair, stored, key).merge(pair_book_id: other) unless stored.include?(key)
          end

          outcome, records = classify(stored, key, answer)
          kept = (outcome == :replaced) ? agreeing_old_keys(stored, records) : []
          set_work_key(stored, key)
          flag_duplicate_holder(key, work) unless outcome == :confirmed
          {outcome: outcome, old_keys: stored, new_key: key, pair_book_id: other,
           duplicate_keys: save_duplicates(answer.duplicates + kept, key, work),
           author_changes: AuthorKeys.call(book: @book, work: work)}
        end

        # [outcome, Open Library's records for the stored keys (nil when not fetched)].
        # updated rather than replaced: an old key Open Library redirects to the answer.
        def classify(stored, key, answer)
          return [:confirmed, nil] if stored.include?(key)
          return [:keyed, nil] if stored.empty?
          return [:updated, nil] if stored.intersect?(answer.redirect_sources)

          records = @client.works_batch(stored)
          [(stored.any? { |old| records[old]&.key == key }) ? :updated : :replaced, records]
        end

        # A replaced key whose own record is the same book (title and an author
        # agree) is another Open Library record of it: kept as a duplicate key.
        def agreeing_old_keys(stored, records)
          stored.select do |old|
            record = records[old]
            record && record.key == old && Check.verified?(@book, record, @client)
          end
        end

        # No trusted answer. A stored key whose record is clearly another book
        # (title and author both disagree) is removed; a dead key, or a record
        # that agrees on either, stays.
        # The key Open Library itself named for this book is never removed.
        def unsure_or_removed(stored, ol_pick)
          candidates = stored - [ol_pick]
          return unchanged(:unsure, stored, nil) if candidates.empty?

          records = @client.works_batch(candidates)
          wrong = candidates.select { |old| (record = records[old]) && Check.clearly_different?(@book, record, @client) }
          return unchanged(:unsure, stored, nil) if wrong.empty?

          @book.identifiers.where(identifier_type: WORK_KEY, value: wrong).destroy_all
          unchanged(:removed, stored, nil)
        end

        def unchanged(outcome, stored, key)
          {outcome: outcome, old_keys: stored, new_key: key, duplicate_keys: [], pair_book_id: nil, author_changes: {}}
        end

        def stored_keys
          @book.identifiers.where(identifier_type: WORK_KEY).order(:id).pluck(:value)
        end

        # The lowest-id other book holding this key as its work key (or as
        # `type`) that really looks like the matched work: its title agrees.
        # A book holding the key wrongly is no holder. Title only: the other
        # book's authors can be missing in legacy data.
        def book_holding(key, work, type = WORK_KEY)
          ids = ::Identifier.where(identifiable_type: "Books::Book", identifier_type: type, value: key)
            .where.not(identifiable_id: @book.id).pluck(:identifiable_id)
          return nil if ids.empty?

          ::Books::Book.where(id: ids).order(:id).find { |other| Check.titles_agree?(other, work) }&.id
        end

        def set_work_key(stored, key)
          @book.identifiers.where(identifier_type: WORK_KEY).where.not(value: key).destroy_all
          @book.identifiers.where(identifier_type: DUPLICATE_KEY, value: key).destroy_all
          @book.identifiers.create!(identifier_type: WORK_KEY, value: key) unless stored.include?(key)
        end

        # Spec section 1, "Open Library's duplicate works": only /resolve
        # returns them. One another book holds as its work key is a pair.
        def save_duplicates(duplicates, key, work)
          held = @book.identifiers.where(identifier_type: DUPLICATE_KEY).pluck(:value)
          duplicates.uniq.each_with_object([]) do |duplicate, saved|
            next if duplicate == key || held.include?(duplicate)

            if (other = book_holding(duplicate, work))
              flag_books(other, duplicate)
            else
              @book.identifiers.create!(identifier_type: DUPLICATE_KEY, value: duplicate)
              saved << duplicate
            end
          end
        end

        # Another book holds the key we just gave this one as a duplicate key.
        def flag_duplicate_holder(key, work)
          other = book_holding(key, work, DUPLICATE_KEY)
          flag_books(other, key) if other
        end

        def flag_books(other, key)
          ::Services::DuplicateCandidates::Flag.call(
            item_type: "Books::Book", ids: [@book.id, other], source: :ol_backfill,
            evidence: {reason: "Open Library matched both books to #{key}", open_library_key: key}
          )
        end
      end
    end
  end
end
