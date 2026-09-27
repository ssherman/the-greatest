# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      # The authors finder's external source: the Open Library author record
      # for the query's own key (GET /authors/{key}; the service resolves
      # redirects). The service has no author name search, so a query without
      # a key contributes nothing.
      #
      # Fetching by the caller's own key is treated as an accept: the rules
      # still require a local holder's name to agree with the query before it
      # matches (FinderBase#corroborated?), and with no local holder, rule 5
      # hands the record to the provider through match.external.
      #
      # Not a `Sources` module on purpose: DataImporters::Sources is the
      # shared one and a nested module of the same name would shadow it.
      class OpenLibrarySource
        def initialize(query:, client: nil)
          @query = query
          @client = client
        end

        def name
          :open_library
        end

        # Raises whatever the client raises except a 404 (circuit open,
        # timeout, 5xx, parse): the finder records that as a failed source.
        def call
          key = @query.open_library_author_key
          return [] if key.blank?

          author = client.author(key)
          holders = local_holders(([author.key, key] + Array(author.redirected_from)).compact_blank.uniq)
          return [build(author, plain_evidence(author))] if holders.empty?

          holders.map { |holder| build(author, external_evidence(author), record: holder) }
        rescue ::Books::OpenLibrary::Exceptions::NotFoundError
          []
        end

        # Lazy: building the default client constructs a CircuitBreaker
        # against REDIS_POOL, and a test that injects its own must never
        # trigger that.
        def client
          @client ||= ::Books::OpenLibrary::Client.new
        end

        private

        def plain_evidence(author)
          {
            external_verdict: "accept", title: author.name, year: author.birth_year,
            alternate_names: author.alternate_names, birth_year: author.birth_year, death_year: author.death_year
          }
        end

        # Holder candidates carry the Open Library values under external_
        # keys: FinderBase merges the local record's own evidence underneath,
        # and a plain key here would overwrite the local value.
        def external_evidence(author)
          {
            external_verdict: "accept", external_title: author.name, external_year: author.birth_year,
            external_alternate_names: author.alternate_names, external_birth_year: author.birth_year,
            external_death_year: author.death_year
          }
        end

        def build(author, evidence, record: nil)
          Candidate.new(
            record: record,
            external_key: author.key,
            external_source: :open_library,
            external_record: author,
            sources: [:open_library],
            evidence: evidence
          )
        end

        def local_holders(keys)
          ::Books::Author
            .joins(:identifiers)
            .where(identifiers: {identifier_type: ::Identifier.identifier_types[:books_author_openlibrary_id], value: keys})
            .distinct
            .order(:id)
            .to_a
        end
      end
    end
  end
end
