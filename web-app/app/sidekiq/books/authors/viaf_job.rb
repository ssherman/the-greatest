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
# The chain never waits on VIAF (spec §8). A job VIAF cannot serve now
# -- a pause (Viaf::Exceptions::Paused: a Cloudflare block, a 429, the
# day's budget running low; an hour or more) or a busy pace -- takes the
# next start time in Viaf::Schedule's line rather than retrying on a fixed
# short delay. When VIAF is paused, or that start is more than
# CHAIN_PATIENCE away, the author goes on to the AI step at once and the
# job is rescheduled with enrich_queued, so later attempts neither queue
# the AI step again nor queue it when they finish. Facts a late VIAF run
# finds land as fills.
class Books::Authors::ViafJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  RESCHEDULE_JITTER = 0..30

  # The longest the AI step waits for VIAF. A turn further off than this
  # queues the AI step now, as a pause does; VIAF's facts land as fills
  # when its turn comes.
  CHAIN_PATIENCE = 600

  def perform(author_id, refresh = false, enrich_queued = false, allow_research = true)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    result = ::Services::Books::Authors::EnrichFromViaf.call(author: author, refresh: refresh)
    if result.data[:wikidata_qid] && !result.data[:decision].needs_review
      ::Books::Authors::WikidataJob.perform_async(author_id, true, true, allow_research)
    elsif !enrich_queued
      ::Books::Authors::EnrichJob.perform_async(author_id, allow_research)
    end
  rescue ::Viaf::Exceptions::RateLimited => e
    # Paused is a RateLimited: VIAF is out for an hour or more. Either way
    # the job takes its turn in the line, and the AI step is queued now when
    # VIAF is paused or the turn is more than CHAIN_PATIENCE away.
    wait = ::Viaf::Schedule.new.reserve(not_before: e.retry_after)
    hand_off = !enrich_queued && (e.is_a?(::Viaf::Exceptions::Paused) || wait > CHAIN_PATIENCE)
    ::Books::Authors::EnrichJob.perform_async(author_id, allow_research) if hand_off
    self.class.perform_in(wait + rand(RESCHEDULE_JITTER), author_id, refresh, enrich_queued || hand_off, allow_research)
  end
end
