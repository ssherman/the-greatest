# frozen_string_literal: true

# One author through Services::Books::Authors::EnrichFromViaf (spec §8,
# §11), only after a Wikidata miss. On the low queue, not serial.
#
# When the matched cluster named a Wikidata item this run stamped, and the
# VIAF decision itself does not need review, Wikidata runs once more for it
# -- forced, since the earlier miss counts as processed, and with via_viaf,
# so a second miss cannot send the author back here. That run goes on to
# the AI step itself. A decision flagged needs_review is not sent back: the
# Wikidata run's held-id path would treat the stamped id as independent
# evidence and record a certain match, turning an uncertain VIAF pick into
# a certain Wikidata one. Every other run goes on to Books::Authors::EnrichJob.
#
# The chain never waits on VIAF (spec §8). A pause (Viaf::Exceptions::Paused:
# a Cloudflare block, a 429, or the day's budget running low; an hour or
# more) sends the author to the AI step at once and reschedules this job
# with enrich_queued, so later attempts neither queue the AI step again nor
# queue it when they finish. A busy pace clears in seconds, so it only
# reschedules. Facts a late VIAF run finds land as fills.
class Books::Authors::ViafJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  RESCHEDULE_JITTER = 0..30

  def perform(author_id, refresh = false, enrich_queued = false)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    result = ::Services::Books::Authors::EnrichFromViaf.call(author: author, refresh: refresh)
    if result.data[:wikidata_qid] && !result.data[:decision].needs_review
      ::Books::Authors::WikidataJob.perform_async(author_id, true, true)
    elsif !enrich_queued
      ::Books::Authors::EnrichJob.perform_async(author_id)
    end
  rescue ::Viaf::Exceptions::Paused => e
    ::Books::Authors::EnrichJob.perform_async(author_id) unless enrich_queued
    reschedule(e, author_id, refresh, true)
  rescue ::Viaf::Exceptions::RateLimited => e
    reschedule(e, author_id, refresh, enrich_queued)
  end

  private

  def reschedule(error, author_id, refresh, enrich_queued)
    self.class.perform_in(error.retry_after.to_i + rand(RESCHEDULE_JITTER), author_id, refresh, enrich_queued)
  end
end
