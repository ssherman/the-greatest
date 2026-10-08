# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 1, passes 1 and 2: which Open Library work, if any, this
      # book is. Raises the client's errors (a 404 on an identifier is no
      # hit); Run retries them.
      class Lookup
        Answer = Data.define(:work, :lookup, :duplicates, :redirect_sources, :source_version)

        FAST_TYPES = {
          "books_work_isbn13" => "isbn13",
          "books_work_isbn10" => "isbn10",
          "books_work_goodreads_id" => "goodreads"
        }.freeze
        # Enough lookups to show whether a book's identifiers agree.
        MAX_FAST_LOOKUPS = 10

        def self.call(book:, client:)
          new(book, client).call
        end

        def initialize(book, client)
          @book = book
          @client = client
        end

        def call
          fast || full
        end

        private

        def identifiers
          @identifiers ||= @book.identifiers.where(identifier_type: FAST_TYPES.keys).order(:id).pluck(:identifier_type, :value)
        end

        def values(type) = identifiers.select { |held, _| held == type }.map(&:last)

        def stored_keys
          @book.identifiers.where(identifier_type: :books_work_openlibrary_id).order(:id).pluck(:value)
        end

        def fast
          return nil if identifiers.empty?

          hits = identifiers.first(MAX_FAST_LOOKUPS).flat_map { |type, value| hits_for(FAST_TYPES.fetch(type), value) }
          keys = hits.map(&:work_key).compact.uniq
          return nil unless keys.size == 1

          work = @client.works_batch(keys)[keys.first]
          return nil unless work && Check.agree?(@book, work)

          Answer.new(work: work, lookup: :identifiers, duplicates: [], redirect_sources: [], source_version: work.source_version)
        end

        def hits_for(type, value)
          @client.identifier(type, value)
        rescue ::Books::OpenLibrary::Exceptions::NotFoundError
          []
        end

        def full
          resolution = @client.resolve(
            title: @book.title.to_s,
            author_names: @book.authors.map(&:name),
            year: @book.first_published_year,
            isbn13: values("books_work_isbn13"),
            isbn10: values("books_work_isbn10"),
            goodreads_id: values("books_work_goodreads_id"),
            existing_ol_key: stored_keys.first
          )
          accepted = resolution.accepted
          work = accepted&.record
          unless work && Check.agree?(@book, work)
            return Answer.new(work: nil, lookup: :resolve, duplicates: [], redirect_sources: [], source_version: resolution.source_version)
          end

          Answer.new(work: work, lookup: :resolve, duplicates: resolution.decision.duplicates.uniq - [work.key],
            redirect_sources: Array(accepted.redirect_sources), source_version: resolution.source_version)
        end
      end
    end
  end
end
