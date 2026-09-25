# frozen_string_literal: true

# One book through Services::Books::EnrichBook. Fill-blanks makes a retry,
# a re-run, and two concurrent runs on one book all safe, so this does not
# need the serial queue. It runs on :low rather than :default because
# :default is shared with Stripe webhook processing, cache purges and
# search indexing under a strict queue order (critical, default, low), and
# an AI enrichment call has no latency requirement those do.
class Books::EnrichBookJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  # author_names lets the importer enrich a brand-new book before it has
  # book_authors rows; the runner falls back to book.authors when empty.
  def perform(book_id, force_research = false, author_names = [])
    book = ::Books::Book.find_by(id: book_id)
    # Deleted between enqueue and run: nothing to do, not worth three retries.
    return if book.nil?

    result = ::Services::Books::EnrichBook.call(
      book: book,
      force_research: force_research,
      author_names: Array(author_names)
    )
    return if result.success?

    raise StandardError, "Enrichment failed for book #{book_id}: #{result.errors.join("; ")}"
  end
end
