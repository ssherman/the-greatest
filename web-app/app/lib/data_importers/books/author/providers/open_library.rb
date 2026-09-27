# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      module Providers
        # Fills a ::Books::Author from its Open Library author record: blank
        # birth_year and death_year, alternate_names unioned (Open Library's
        # own name included when it differs), and the canonical key stamped as
        # books_author_openlibrary_id. `name` is written only when blank (a
        # key-only import); a populated name is never touched.
        #
        # The record comes from the finder's match when it already fetched one
        # (rule 5, or the AI choosing the Open Library candidate), else from
        # the query's key, else from the author's held key. An author with no
        # key has nothing to look up: success with nothing populated.
        class OpenLibrary < DataImporters::ProviderBase
          FILLABLE_YEARS = %w[birth_year death_year].freeze

          def initialize(client: nil)
            @client = client
          end

          # Lazy: building the default client constructs a CircuitBreaker
          # against REDIS_POOL, and a test that injects its own client should
          # never trigger that.
          def client
            @client ||= ::Books::OpenLibrary::Client.new
          end

          def populate(author, query:, match: nil)
            record = reusable_record(match) || fetch(author, query)
            return success_result(data_populated: []) if record.nil?

            success_result(data_populated: apply(author, record))
          rescue => e
            failure_result(errors: ["Open Library #{e.class.name.demodulize}: #{e.message}"])
          end

          private

          def reusable_record(match)
            external = match&.external
            return nil unless external&.external_source == :open_library

            external.external_record
          end

          def fetch(author, query)
            key = query&.open_library_author_key || held_key(author)
            return nil if key.blank?

            client.author(key)
          end

          def held_key(author)
            author.identifiers.find { |identifier| identifier.identifier_type == "books_author_openlibrary_id" }&.value
          end

          def apply(author, record)
            populated = []

            if author.name.blank? && record.name.present?
              author.name = record.name
              populated << "name"
            end

            FILLABLE_YEARS.each do |field|
              value = record.public_send(field)
              next if value.nil? || author[field].present?

              author[field] = value
              populated << field
            end

            added = new_alternate_names(author, record)
            if added.any?
              author.alternate_names = Array(author.alternate_names) + added
              populated << "alternate_names"
            end

            author.identifiers.find_or_initialize_by(identifier_type: :books_author_openlibrary_id, value: record.key)
            populated
          end

          def new_alternate_names(author, record)
            held = ([author.name] + Array(author.alternate_names)).map { |name| normalize(name) }
            ([record.name] + Array(record.alternate_names))
              .map(&:to_s).compact_blank
              .reject { |name| held.include?(normalize(name)) }
              .uniq { |name| normalize(name) }
          end

          def normalize(text)
            ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
          end
        end
      end
    end
  end
end
