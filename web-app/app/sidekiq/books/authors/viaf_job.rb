# frozen_string_literal: true

# One author through Services::Books::Authors::EnrichFromViaf (spec §8,
# §11), only after a Wikidata miss. On the low queue, not serial. VIAF paused
# (a Cloudflare block, or the day's budget running low) or our pace busy
# reschedules this job for the wait RateLimited carries, so no worker thread
# sleeps. When the matched cluster named a Wikidata item this run stamped,
# Wikidata runs once more for it -- forced, since the earlier miss counts as
# processed, and with via_viaf, so a second miss cannot send the author back
# here. The chain ends here until the AI step lands.
class Books::Authors::ViafJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  RESCHEDULE_JITTER = 0..30

  def perform(author_id, refresh = false)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    result = ::Services::Books::Authors::EnrichFromViaf.call(author: author, refresh: refresh)
    return if result.data[:wikidata_qid].nil?

    ::Books::Authors::WikidataJob.perform_async(author_id, true, true)
  rescue ::Viaf::Exceptions::RateLimited => e
    self.class.perform_in(e.retry_after.to_i + rand(RESCHEDULE_JITTER), author_id, refresh)
  end
end
