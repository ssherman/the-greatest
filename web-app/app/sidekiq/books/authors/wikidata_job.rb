# frozen_string_literal: true

# One author through Services::Books::Authors::EnrichFromWikidata (spec §11).
# On the author_chain queue, last in strict order, after low: it has no
# latency requirement. Expected failures write a failed ledger row inside the
# runner and do not raise. A rate limit (a 429, maxlag, or our own pace busy
# for longer than the inline wait) reschedules this job rather than holding
# a worker thread. A miss goes on to Books::Authors::ViafJob, unless VIAF sent
# this author here (via_viaf), which would loop. Every other outcome --
# matched, failed, skipped, or a via_viaf miss -- goes on to the AI step,
# Books::Authors::EnrichJob, so every chain ends there. allow_research
# (false for the backfill, spec §13) travels with the author to every later
# step.
class Books::Authors::WikidataJob
  include Sidekiq::Job

  sidekiq_options queue: :author_chain, retry: 3

  RESCHEDULE_JITTER = 0..30

  def perform(author_id, refresh = false, via_viaf = false, allow_research = true)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    result = ::Services::Books::Authors::EnrichFromWikidata.call(author: author, refresh: refresh)
    if result.data[:outcome] == :unmatched && !via_viaf
      ::Books::Authors::ViafJob.perform_async(author_id, refresh, false, allow_research)
    else
      ::Books::Authors::EnrichJob.perform_async(author_id, allow_research)
    end
  rescue ::Wikimedia::Exceptions::RateLimited => e
    self.class.perform_in(e.retry_after.to_i + rand(RESCHEDULE_JITTER), author_id, refresh, via_viaf, allow_research)
  end
end
