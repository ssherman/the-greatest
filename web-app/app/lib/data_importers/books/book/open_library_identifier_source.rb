# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Pass one of the Goodreads replay (spec §12.3): the fast Open Library
      # lookup. Asks the data service which work each of the query's ISBN-13s,
      # ISBN-10s and Goodreads ids belongs to (GET /identifiers, milliseconds,
      # unlike /resolve's 5-6 s) and returns the local books holding those
      # works' keys, or a key they redirect from. That is evidence for the
      # rules and the AI, never a verdict: no rule treats it as decisive.
      #
      # An identifier the service does not know is an empty answer; one it
      # refuses (422) is no candidate rather than a failed source. Anything
      # else raises, and the finder records the source as failed.
      class OpenLibraryIdentifierSource
        LOOKUPS = [[:isbn13, "isbn13"], [:isbn10, "isbn10"], [:goodreads_id, "goodreads"]].freeze

        def initialize(query:, client: nil)
          @query = query
          @client = client
        end

        def name
          :open_library_identifier
        end

        def call
          matched = {}
          LOOKUPS.each do |field, type|
            Array(@query.public_send(field)).each do |value|
              hits(type, value).each do |hit|
                [hit.work_key, *hit.redirected_from].compact_blank.each { |key| matched[key] ||= {type: "open_library #{type}", value: value} }
              end
            end
          end
          return [] if matched.empty?

          holders(matched.keys).map do |book, key|
            Candidate.new(record: book, sources: [:open_library_identifier], evidence: {matched_identifier: matched.fetch(key)})
          end
        end

        # Lazy, as in OpenLibrarySource: the default client builds a circuit
        # breaker against REDIS_POOL, which a test that injects its own must
        # never trigger.
        def client
          @client ||= ::Books::OpenLibrary::Client.new
        end

        private

        def hits(type, value)
          client.identifier(type, value)
        rescue ::Books::OpenLibrary::Exceptions::ClientError
          []
        end

        def holders(keys)
          rows = ::Identifier.where(identifiable_type: "Books::Book",
            identifier_type: ::Identifier.identifier_types[:books_work_openlibrary_id], value: keys)
            .order(:identifiable_id).pluck(:identifiable_id, :value)
          books = ::Books::Book.where(id: rows.map(&:first)).index_by(&:id)
          rows.uniq(&:first).filter_map { |book_id, key| [books[book_id], key] if books[book_id] }
        end
      end
    end
  end
end
