# frozen_string_literal: true

# One author through Services::Books::Authors::EnrichAuthor (spec §9-§11),
# the chain's last step, on the low queue. A failed AI run raises, so
# Sidekiq retries it as it does a book's. The books whose enrichment waited
# for this author (Services::Books::DeferredEnrichment) are then handed on
# to Books::EnrichBookJob: after a successful run, or once the retries are
# exhausted, so the hand-off happens once either way.
class Books::Authors::EnrichJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  sidekiq_retries_exhausted do |job, _exception|
    hand_off(job["args"].first)
  end

  def self.hand_off(author_id)
    author = ::Books::Author.find_by(id: author_id)
    return if author.nil?

    ::Services::Books::DeferredEnrichment.waiting_book_ids(author).each { |book_id| ::Books::EnrichBookJob.perform_async(book_id) }
  end

  def perform(author_id, allow_research = true)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    result = ::Services::Books::Authors::EnrichAuthor.call(author: author, allow_research: allow_research)
    raise StandardError, "Author enrichment failed for author #{author_id}: #{result.errors.join("; ")}" unless result.success?

    self.class.hand_off(author_id)
  end
end
