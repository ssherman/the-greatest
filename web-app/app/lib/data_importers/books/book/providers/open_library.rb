# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # Calls the Open Library /resolve service and applies only what it marks
        # as a "fill" -- a populated local field is never overwritten, even when
        # the service disagrees with it. Conflicting and enriching fields are
        # left alone and reported in data_populated as "skipped:<field>" so a
        # human can see them; deciding a conflict belongs to the reconciliation
        # spec, not to this provider.
        class OpenLibrary < DataImporters::ProviderBase
          # The Books::Book scalar columns the service's work-level diff covers.
          # authors/subjects also appear in the diff, but creating authors or
          # categories from them belongs to the reconciliation spec.
          FILLABLE_FIELDS = %w[title subtitle description first_published_year].freeze

          IDENTIFIER_TYPE_BY_QUERY_FIELD = {
            isbn13: :books_work_isbn13,
            isbn10: :books_work_isbn10,
            asin: :books_work_asin,
            goodreads_id: :books_work_goodreads_id
          }.freeze

          def initialize(client: nil)
            @client = client
          end

          # Lazy: building the default client constructs a CircuitBreaker
          # against REDIS_POOL, and a test that injects its own client should
          # never trigger that.
          def client
            @client ||= ::Books::OpenLibrary::Client.new
          end

          # book: ::Books::Book -- the local record. query: DataImporters::Books::Book::ImportQuery
          # or nil (item-based / force_providers import, where the book alone
          # must carry everything the request needs).
          def populate(book, query: nil)
            resolution = client.resolve(**resolve_args(book, query))

            if resolution.accept?
              apply_accept(book, resolution)
            elsif resolution.abstain?
              failure_result(errors: ["Open Library abstained: #{resolution.decision.reason}"])
            else
              failure_result(errors: ["Open Library rejected: #{resolution.decision.reason}"])
            end
          rescue => e
            failure_result(errors: ["Open Library #{e.class.name.demodulize}: #{e.message}"])
          end

          private

          # The service guarantees an accept decision names a candidate with
          # that key, but this is defensive rather than trusted blindly.
          def apply_accept(book, resolution)
            candidate = resolution.accepted
            return failure_result(errors: ["Open Library accepted with no matching candidate"]) unless candidate

            data_populated = apply_fills(book, candidate) + report_skipped(candidate)

            book.identifiers.find_or_initialize_by(
              identifier_type: :books_work_openlibrary_id,
              value: candidate.work_key
            )

            success_result(data_populated: data_populated)
          end

          # Only a fill on a field that is actually blank locally gets
          # written -- belt and braces alongside the service's own "ours was
          # absent" judgment.
          def apply_fills(book, candidate)
            candidate.fills.filter_map do |entry|
              next unless FILLABLE_FIELDS.include?(entry.field)
              next unless book[entry.field].blank?

              book[entry.field] = entry.theirs
              entry.field
            end
          end

          def report_skipped(candidate)
            (candidate.conflicts + candidate.enrichments).filter_map do |entry|
              "skipped:#{entry.field}" if FILLABLE_FIELDS.include?(entry.field)
            end
          end

          # R106: the request IS the local record. Built from the book's
          # current state (falling back to the query only where the book has
          # nothing yet), so the service's diff.ours is always what the book
          # actually holds -- never what the caller merely asked to import.
          def resolve_args(book, query)
            {
              title: book.title.presence || query&.title,
              subtitle: book.subtitle,
              description: book.description,
              author_names: author_names_for(book, query),
              year: book.first_published_year || query&.year,
              isbn13: identifier_values(book, query, :isbn13),
              isbn10: identifier_values(book, query, :isbn10),
              asin: identifier_values(book, query, :asin),
              goodreads_id: identifier_values(book, query, :goodreads_id),
              existing_ol_key: existing_ol_key(book, query)
            }
          end

          def author_names_for(book, query)
            names = book.authors.map(&:name)
            names.presence || query&.author_names || []
          end

          # Union of the query's identifiers and the book's own identifier
          # rows of the matching type -- a re-run must not drop an identifier
          # the query no longer repeats.
          def identifier_values(book, query, query_field)
            identifier_type = IDENTIFIER_TYPE_BY_QUERY_FIELD.fetch(query_field)
            from_query = query ? Array(query.public_send(query_field)) : []
            from_book = book.identifiers.select { |identifier| identifier.identifier_type == identifier_type.to_s }.map(&:value)
            (from_query + from_book).uniq
          end

          def existing_ol_key(book, query)
            query&.open_library_work_key ||
              book.identifiers.find { |identifier| identifier.identifier_type == "books_work_openlibrary_id" }&.value
          end
        end
      end
    end
  end
end
