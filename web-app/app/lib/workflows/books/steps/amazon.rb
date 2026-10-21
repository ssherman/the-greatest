# frozen_string_literal: true

# The Amazon step of the book workflow: a copy of the body of
# Books::AmazonProductEnrichmentJob. That job is still live (the
# books:amazon_enrich* rake tasks call it), so the two must be kept in step.
# Failure raises, so the coordinator retries it (three attempts, where the
# job's implicit Sidekiq retry count was 25).
module Workflows
  module Books
    module Steps
      class Amazon
        def call(step:, run:, target:)
          Rails.logger.info "Starting Amazon product enrichment for book: #{target.title}"

          result = ::Services::Books::AmazonProductService.call(book: target)

          # Stamped before the raise on purpose. The coordinator owns retries; this
          # column owns sweep coverage. Stamping only on success would make a
          # permanently unmatchable book re-enqueue on every sweep, forever.
          target.update_column(:amazon_enriched_at, Time.current)

          if result[:success]
            if result[:errors].present?
              Rails.logger.error "Amazon enrichment for #{target.title} succeeded with #{result[:errors].size} per-product failures: #{result[:errors].join("; ")}"
            end
            Rails.logger.info "Amazon enrichment completed for #{target.title}: #{result[:data]}"
            Workflows::Outcome.succeeded("done")
          else
            error_message = result[:error] || result[:errors]&.join(", ") || "Unknown error"
            Rails.logger.error "Failed to enrich book #{target.title}: #{error_message}"
            raise StandardError, "Amazon enrichment failed: #{error_message}"
          end
        end
      end
    end
  end
end
