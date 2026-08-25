# frozen_string_literal: true

class Books::AmazonProductEnrichmentJob
  include Sidekiq::Job

  sidekiq_options queue: :serial

  def perform(book_id)
    book = ::Books::Book.find_by!(id: book_id)

    Rails.logger.info "Starting Amazon product enrichment for book: #{book.title}"

    result = ::Services::Books::AmazonProductService.call(book: book)

    # Stamped before the raise on purpose. Sidekiq owns retries; this column owns
    # sweep coverage. Stamping only on success would make a permanently
    # unmatchable book re-enqueue on every sweep, forever.
    book.update_column(:amazon_enriched_at, Time.current)

    if result[:success]
      if result[:errors].present?
        Rails.logger.error "Amazon enrichment for #{book.title} succeeded with #{result[:errors].size} per-product failures: #{result[:errors].join("; ")}"
      end
      Rails.logger.info "Amazon enrichment completed for #{book.title}: #{result[:data]}"
    else
      error_message = result[:error] || result[:errors]&.join(", ") || "Unknown error"
      Rails.logger.error "Failed to enrich book #{book.title}: #{error_message}"
      raise StandardError, "Amazon enrichment failed: #{error_message}"
    end
  end
end
