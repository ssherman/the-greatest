# frozen_string_literal: true

# One author through Services::Books::Authors::EnrichFromWikidata (spec §11).
# On the low queue: it has no latency requirement, and low is last in the
# strict queue order. Expected failures write a failed ledger row inside the
# runner and do not raise. A rate limit (a 429, maxlag, or our own pace busy
# for longer than the inline wait) reschedules this job rather than holding
# a worker thread. A miss goes on to Books::Authors::ViafJob, unless VIAF sent
# this author here (via_viaf), which would loop. The chain ends at VIAF until
# the AI step lands.
class Books::Authors::WikidataJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  RESCHEDULE_JITTER = 0..30

  def perform(author_id, refresh = false, via_viaf = false)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    result = ::Services::Books::Authors::EnrichFromWikidata.call(author: author, refresh: refresh)
    return unless result.data[:outcome] == :unmatched && !via_viaf

    ::Books::Authors::ViafJob.perform_async(author_id, refresh)
  rescue ::Wikimedia::Exceptions::RateLimited => e
    self.class.perform_in(e.retry_after.to_i + rand(RESCHEDULE_JITTER), author_id, refresh, via_viaf)
  end
end
