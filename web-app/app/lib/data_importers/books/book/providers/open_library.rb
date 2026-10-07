# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # Calls the Open Library /resolve service -- or, for a new book whose
        # match already carries the finder's resolution, reuses that answer
        # instead of asking again -- and applies only what it marks as a
        # "fill" -- a populated local field is never overwritten, even when
        # the service disagrees with it. Conflicting and enriching fields are
        # left alone and reported in data_populated as "skipped:<field>" so a
        # human can see them; deciding a conflict belongs to the reconciliation
        # spec, not to this provider.
        class OpenLibrary < DataImporters::ProviderBase
          # The Books::Book scalar columns the service's work-level diff covers.
          # Authors are not a diff fill: on accept, a book with no authors gets
          # the accepted work's authors through the author importer
          # (link_open_library_authors). Subjects stay the categories spec's.
          FILLABLE_FIELDS = %w[title subtitle description first_published_year].freeze

          IDENTIFIER_TYPE_BY_QUERY_FIELD = {
            isbn13: :books_work_isbn13,
            isbn10: :books_work_isbn10,
            asin: :books_work_asin,
            goodreads_id: :books_work_goodreads_id
          }.freeze

          def initialize(client: nil, new_author_ids: [], provisional: false, trust_work_key: false)
            @client = client
            @new_author_ids = new_author_ids
            @provisional = provisional
            @trust_work_key = trust_work_key
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
          def populate(book, query: nil, match: nil)
            trusted_key = trusted_work_key(query)
            resolution = begin
              reusable_resolution(book, match) || client.resolve(**resolve_args(book, query))
            rescue => e
              # A person chose this work; an unreachable service must not lose
              # it. Without a trusted key the error is reported as before.
              raise e unless trusted_key

              nil
            end

            if trusted_key
              apply_trusted(book, resolution, query, trusted_key)
            elsif resolution.accept?
              apply_accept(book, resolution, query)
            elsif resolution.abstain?
              failure_result(errors: ["Open Library abstained: #{resolution.decision.reason}"])
            else
              failure_result(errors: ["Open Library rejected: #{resolution.decision.reason}"])
            end
          rescue => e
            failure_result(errors: ["Open Library #{e.class.name.demodulize}: #{e.message}"])
          end

          private

          # The finder already asked the service about this query. For a book
          # that does not exist yet, the request the provider would build is
          # the same one (title and year seeded from the query; no authors or
          # identifiers of its own yet), so the answer is reused instead of a
          # second call to a slow service. A persisted book under force_providers
          # resolves from its own state, as before. The finder's request also
          # carries `limit: 5`, which only truncates the returned candidate
          # list, never the verdict.
          def reusable_resolution(book, match)
            return nil if book.persisted? || match.nil?

            match.external_resolution
          end

          # A person confirmed this work (the list wizard's Review, books list
          # wizard spec §6), so it wins over the service's own choice. Applied
          # like an accept when /resolve returned it; otherwise only its key is
          # stamped and the Authors provider links authors by name.
          def trusted_work_key(query)
            @trust_work_key ? query&.open_library_work_key : nil
          end

          def apply_trusted(book, resolution, query, key)
            candidate = resolution&.candidates&.find { |entry| entry.work_key == key }
            return apply_candidate(book, candidate, query) if candidate
            return failure_result(errors: ["Open Library work #{key} was chosen but the book has no title"]) if book.title.blank?

            book.identifiers.find_or_initialize_by(identifier_type: :books_work_openlibrary_id, value: key)
            persist_query_identifiers(book, query)
            success_result(data_populated: ["open_library_work_key"])
          end

          # The service guarantees an accept decision names a candidate with
          # that key, but this is defensive rather than trusted blindly.
          def apply_accept(book, resolution, query)
            candidate = resolution.accepted
            return failure_result(errors: ["Open Library accepted with no matching candidate"]) unless candidate

            apply_candidate(book, candidate, query)
          end

          def apply_candidate(book, candidate, query)
            filled = apply_fills(book, candidate)

            # R113: ImporterBase#run_providers_with_saving skips save! when
            # item.valid? is false but still keeps this provider's success --
            # so an identifier-only import whose title diff was "absent"
            # (never filled) would otherwise report success with nothing
            # persisted. Bail before any identifier gets stamped on a book
            # that cannot be saved.
            if book.title.blank?
              return failure_result(errors: ["Open Library accepted #{candidate.work_key} but the book still has no title"])
            end

            data_populated = filled + report_skipped(candidate)

            book.identifiers.find_or_initialize_by(
              identifier_type: :books_work_openlibrary_id,
              value: candidate.work_key
            )

            persist_query_identifiers(book, query)

            data_populated << "authors" if link_open_library_authors(book, candidate)

            success_result(data_populated: data_populated)
          end

          # R112: these are the CALLER's assertions about the book (the same
          # trust as the title), not service data -- never persisted from the
          # service's `record`. Re-running Importer.call(isbn13: [...]) twice
          # used to create two books: apply_accept persisted only the OL key,
          # so the finder's identifier lookup on the second run had nothing
          # of the query's own identifiers to find.
          def persist_query_identifiers(book, query)
            return unless query

            IDENTIFIER_TYPE_BY_QUERY_FIELD.each do |query_field, identifier_type|
              Array(query.public_send(query_field)).each do |value|
                book.identifiers.find_or_initialize_by(identifier_type: identifier_type, value: value)
              end
            end
          end

          # Import-finder redesign §8: on accept, a book with no authors gets
          # the accepted work's authors, each through the author importer by
          # key and name, linked in Open Library's order. A book that already
          # has authors is left alone (the merger's ruling). Each author is
          # imported without its async enrichment; one this import created is
          # remembered in new_author_ids for the providers after this one
          # (spec §10).
          def link_open_library_authors(book, candidate)
            return false if book.book_authors.any?

            work = candidate.record
            return false if work.nil? || work.author_keys.empty?

            linked = false
            work.author_keys.zip(work.author_names).each_with_index do |(key, name), index|
              imported = ::DataImporters::Books::Author::Importer.call(
                name: name, open_library_author_key: key, work_titles: [book.title].compact_blank,
                providers: ::DataImporters::Books::Author::Importer::BOOK_STEP_PROVIDERS, provisional: @provisional
              )
              author = imported.item
              next unless author&.persisted?

              @new_author_ids << author.id if imported.created?
              next if book.book_authors.any? { |existing| existing.author_id == author.id }

              book.book_authors.build(author: author, position: index + 1)
              linked = true
            end
            book.authors.reset if linked
            linked
          end

          # Only a fill on a field that is actually blank locally gets
          # written -- belt and braces alongside the service's own "ours was
          # absent" judgment.
          #
          # R117: books_books.description is read by no book page and is
          # scheduled for deletion (Books::Book) -- the displayed text lives
          # in the descriptions table. A "description" fill is never written
          # to that column; it goes through Describable#assign_description
          # onto the autosaved descriptions association instead (same
          # precedent as DataImporters::Games::Game::Providers::Igdb), and
          # "locally blank" for description means no primary description,
          # not an empty column.
          def apply_fills(book, candidate)
            candidate.fills.filter_map do |entry|
              next unless FILLABLE_FIELDS.include?(entry.field)

              if entry.field == "description"
                next unless book.primary_description.nil?

                # license: the book page renders the provenance link only for cc0 /
                # cc_by_sa_4 rows; the books migration classifies Open Library text as cc0.
                book.assign_description(
                  source: :openlibrary,
                  content: entry.theirs,
                  source_url: "https://openlibrary.org/works/#{candidate.work_key}",
                  license: :cc0
                )
              else
                next unless book[entry.field].blank?

                book[entry.field] = entry.theirs
              end

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
              description: book.primary_description&.content,
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
            names = book.book_authors.map { |link| link.author.name }
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
