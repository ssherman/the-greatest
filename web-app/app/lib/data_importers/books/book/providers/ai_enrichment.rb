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
        # step linked none.
        class AiEnrichment < DataImporters::ProviderBase
          def populate(book, query:, match: nil)
            return failure_result(errors: ["Book title required for AI enrichment"]) if book.title.blank?

            author_names = book.authors.map(&:name)
            author_names = Array(query&.author_names).map(&:to_s).reject(&:blank?) if author_names.empty?
            return failure_result(errors: ["Book must have an author for AI enrichment"]) if author_names.empty?
            return failure_result(errors: ["Book must be persisted before queuing AI enrichment"]) unless book.persisted?

            ::Books::EnrichBookJob.perform_async(book.id, false, author_names)

            success_result(data_populated: [:ai_enrichment_queued])
          rescue => e
            failure_result(errors: ["AI enrichment provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
