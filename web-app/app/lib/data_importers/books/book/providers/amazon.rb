# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # Async provider: queues Books::AmazonProductEnrichmentJob and returns
        # at once. Runs last in the importer. The job needs an author to build
        # its search, so a book without one fails here rather than failing
        # and retrying in the worker.
        class Amazon < DataImporters::ProviderBase
          def populate(book, query:, match: nil)
            return failure_result(errors: ["Book title required for Amazon enrichment"]) if book.title.blank?
            return failure_result(errors: ["Book must have an author for Amazon enrichment"]) if book.authors.empty?
            return failure_result(errors: ["Book must be persisted before queuing Amazon enrichment"]) unless book.persisted?

            # After the outermost commit: a worker that runs before it would
            # not find the book, and a rolled-back book must queue nothing.
            ::ActiveRecord.after_all_transactions_commit do
              ::Books::AmazonProductEnrichmentJob.perform_async(book.id)
            end

            success_result(data_populated: [:amazon_enrichment_queued])
          rescue => e
            failure_result(errors: ["Amazon provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
