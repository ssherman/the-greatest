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

        def self.record_failure(book:, run_id:, error:)
          row = ::Books::OpenLibraryBackfill.find_or_initialize_by(book: book)
          row.assign_attributes(outcome: :failed, run_id: run_id, error: error.to_s.truncate(1000),
            attempts: row.new_record? ? 1 : row.attempts + 1)
          row.save!
          row
        end

        def initialize(book, client, run_id)
          @book = book
          @client = client
          @run_id = run_id
        end

        def call
          answer = Lookup.call(book: @book, client: @client)
          ::ActiveRecord::Base.transaction do
            row = ::Books::OpenLibraryBackfill.find_or_initialize_by(book: @book)
            attempts = row.new_record? ? 1 : row.attempts + 1
            row.assign_attributes(decide(answer).merge(
              lookup: answer.lookup, run_id: @run_id, attempts: attempts, error: nil,
              dump_date: answer.source_version&.dig(:dump_date), matcher_version: answer.source_version&.dig(:matcher_version)
            ))
            row.save!
            Result.new(success?: true, data: row, errors: [])
          end
        rescue ::ActiveRecord::RecordNotUnique
          Result.new(success?: false, data: nil, errors: ["another run wrote book #{@book.id} first"])
        end

        private

        def decide(answer)
          stored = stored_keys
          work = answer.work
          return unchanged(:unsure, stored, nil) if work.nil?

          key = work.key
          if (other = book_holding(key))
            flag_books(other, key)
            return unchanged(:duplicate_pair, stored, key).merge(pair_book_id: other)
          end

          outcome = if stored.include?(key) then :confirmed
          elsif stored.empty? then :keyed
          elsif redirected?(stored, key, answer) then :updated
          else
            :replaced
          end
          set_work_key(stored, key)
          {outcome: outcome, old_keys: stored, new_key: key, pair_book_id: nil,
           duplicate_keys: save_duplicates(answer.duplicates, key),
           author_changes: AuthorKeys.call(book: @book, work: work)}
        end

        def unchanged(outcome, stored, key)
          {outcome: outcome, old_keys: stored, new_key: key, duplicate_keys: [], pair_book_id: nil, author_changes: {}}
        end

        def stored_keys
          @book.identifiers.where(identifier_type: WORK_KEY).order(:id).pluck(:value)
        end

        # Another book holding this key as its work key.
        def book_holding(key)
          ::Identifier.where(identifiable_type: "Books::Book", identifier_type: WORK_KEY, value: key)
            .where.not(identifiable_id: @book.id).order(:identifiable_id).pick(:identifiable_id)
        end

        # updated rather than replaced: an old key Open Library redirects to the answer.
        def redirected?(stored, key, answer)
          return true if stored.intersect?(answer.redirect_sources)

          records = @client.works_batch(stored)
          stored.any? { |old| records[old]&.key == key }
        end

        def set_work_key(stored, key)
          @book.identifiers.where(identifier_type: WORK_KEY).where.not(value: key).destroy_all
          @book.identifiers.where(identifier_type: DUPLICATE_KEY, value: key).destroy_all
          @book.identifiers.create!(identifier_type: WORK_KEY, value: key) unless stored.include?(key)
        end

        # Spec section 1, "Open Library's duplicate works": only /resolve
        # returns them. One another book holds as its work key is a pair.
        def save_duplicates(duplicates, key)
          held = @book.identifiers.where(identifier_type: DUPLICATE_KEY).pluck(:value)
          duplicates.uniq.each_with_object([]) do |duplicate, saved|
            next if duplicate == key || held.include?(duplicate)

            if (other = book_holding(duplicate))
              flag_books(other, duplicate)
            else
              @book.identifiers.create!(identifier_type: DUPLICATE_KEY, value: duplicate)
              saved << duplicate
            end
          end
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
