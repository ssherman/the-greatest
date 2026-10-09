# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 1, passes 1 and 2: which Open Library work, if any, this
      # book is. Raises the client's errors (a 4xx on an identifier is no
      # hit); Run retries them.
      class Lookup
        # confirm_only: Open Library abstained, but its top candidate is a key the
        # book already holds and agrees with it. Nothing is to be changed.
        Answer = Data.define(:work, :lookup, :duplicates, :redirect_sources, :source_version, :confirm_only) do
          def initialize(work:, lookup:, duplicates:, redirect_sources:, source_version:, confirm_only: false)
            super
          end
        end

        FAST_TYPES = {
          "books_work_isbn13" => "isbn13",
          "books_work_isbn10" => "isbn10",
          "books_work_goodreads_id" => "goodreads"
        }.freeze
        # Enough lookups to show whether a book's identifiers agree.
        MAX_FAST_LOOKUPS = 10
        NO_HIT_STATUSES = [400, 422].freeze
        RESOLVE_IDENTIFIERS_PER_TYPE = 3

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
          return nil unless work && Check.verified?(@book, work, @client)

          Answer.new(work: work, lookup: :identifiers, duplicates: [], redirect_sources: [], source_version: work.source_version)
        end

        def hits_for(type, value)
          @client.identifier(type, value)
        rescue ::Books::OpenLibrary::Exceptions::ClientError => e
          # 404 (unknown), 400/422 (a value the service cannot normalise): no hit.
          # Anything else (401, 403, 429...) is about us, not the book.
          raise unless e.is_a?(::Books::OpenLibrary::Exceptions::NotFoundError) || NO_HIT_STATUSES.include?(e.status_code)

          []
        end

        def full
          resolution = @client.resolve(
            title: @book.title.to_s,
            author_names: @book.authors.map(&:name),
            year: @book.first_published_year,
            isbn13: values("books_work_isbn13").first(RESOLVE_IDENTIFIERS_PER_TYPE),
            isbn10: values("books_work_isbn10").first(RESOLVE_IDENTIFIERS_PER_TYPE),
            goodreads_id: values("books_work_goodreads_id").first(RESOLVE_IDENTIFIERS_PER_TYPE),
            existing_ol_key: stored_keys.first
          )
          accepted = resolution.accepted
          work = accepted&.record
          if work && Check.verified?(@book, work, @client)
            return Answer.new(work: work, lookup: :resolve, duplicates: resolution.decision.duplicates.uniq - [work.key],
              redirect_sources: Array(accepted.redirect_sources), source_version: resolution.source_version)
          end

          held = confirmable_stored_key(resolution)
          Answer.new(work: held, lookup: :resolve, duplicates: [], redirect_sources: [],
            source_version: resolution.source_version, confirm_only: !held.nil?)
        end

        # Not an accept, but the top candidate is a key we hold and its record
        # agrees with the book: famous books with many near-identical Open
        # Library records abstain on margin even then.
        def confirmable_stored_key(resolution)
          return nil if resolution.accept?

          top = resolution.candidates.first
          return nil unless top&.record && stored_keys.include?(top.work_key)

          top.record if Check.verified?(@book, top.record, @client)
        end
      end
    end
  end
end
