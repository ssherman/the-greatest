# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # Async provider: queues Books::EnrichBookJob and returns at once.
        # Runs after OpenLibrary and Authors in the importer so the AI fills fewer blanks.
        #
        # The author step runs first, so book.authors is normally present by
        # now; the query's author names are only the fallback, used when that
        # step linked none. When a linked author was created by this import,
        # the book waits for that author's chain instead (spec §10): a
        # skipped books.book_facts row records the wait, and
        # Books::Authors::EnrichJob hands the book on.
        class AiEnrichment < DataImporters::ProviderBase
          def initialize(new_author_ids: [])
            @new_author_ids = new_author_ids
          end

          def populate(book, query:, match: nil)
            return failure_result(errors: ["Book title required for AI enrichment"]) if book.title.blank?

            author_names = book.authors.map(&:name)
            author_names = Array(query&.author_names).map(&:to_s).reject(&:blank?) if author_names.empty?
            return failure_result(errors: ["Book must have an author for AI enrichment"]) if author_names.empty?
            return failure_result(errors: ["Book must be persisted before queuing AI enrichment"]) unless book.persisted?

            if waits_for_new_authors?(book)
              ::Services::Books::DeferredEnrichment.defer!(book)
              return success_result(data_populated: [:ai_enrichment_deferred_to_authors])
            end

            ::Books::EnrichBookJob.perform_async(book.id, false, author_names)

            success_result(data_populated: [:ai_enrichment_queued])
          rescue => e
            failure_result(errors: ["AI enrichment provider error: #{e.message}"])
          end

          private

          # A linked author this import created has no countries yet. An
          # author it created but did not link never hands this book on, so
          # it does not hold the book back.
          def waits_for_new_authors?(book)
            @new_author_ids.intersect?(book.book_authors.map(&:author_id))
          end
        end
      end
    end
  end
end
