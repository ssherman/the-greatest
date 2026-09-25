# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # Async provider: queues Books::EnrichBookJob and returns at once.
        # Runs after OpenLibrary in the importer so the AI fills fewer blanks.
        #
        # A brand-new book has no book_authors rows (the OpenLibrary provider
        # deliberately creates no authors), so the query's author names ride
        # along to the job; the runner uses book.authors when they exist.
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
