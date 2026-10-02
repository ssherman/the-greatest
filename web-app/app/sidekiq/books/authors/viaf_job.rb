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
# The chain never waits on VIAF (spec §8). VIAF allows two requests a
# minute and about a thousand a day, so jobs that must wait take turns
# from Viaf::Schedule's line: a job not yet in the line joins it whenever
# anyone is waiting, a pause (Viaf::Exceptions::Paused: a Cloudflare
# block, a 429, the day's budget running low) sends a job to the back,
# and a busy pace on a job's own turn (in_line) only delays that turn,
# since one author can need more requests than a minute allows. When VIAF
# is paused, or a job's turn is more than CHAIN_PATIENCE away, the author
# goes on to the AI step at once and the job carries enrich_queued, so
# its later attempts do not queue the AI step themselves. A late VIAF
# match that names a Wikidata item still sends the author through the
# forced Wikidata run, which ends at the AI step again (EnrichAuthor skips
# an author already complete). Facts a late VIAF run finds land as fills.
class Books::Authors::ViafJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  RESCHEDULE_JITTER = 0..30

  # The longest the AI step waits for VIAF. A turn further off than this
  # queues the AI step now, as a pause does; VIAF's facts land as fills
  # when its turn comes.
  CHAIN_PATIENCE = 600

  def perform(author_id, refresh = false, enrich_queued = false, allow_research = true, in_line = false)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    # A job not yet in the line waits behind anyone already in it, rather
    # than competing with them for VIAF's two requests a minute.
    return take_turn(author_id, refresh, enrich_queued, allow_research, not_before: 0) if !in_line && schedule.horizon

    result = ::Services::Books::Authors::EnrichFromViaf.call(author: author, refresh: refresh)
    if result.data[:wikidata_qid] && !result.data[:decision].needs_review
      ::Books::Authors::WikidataJob.perform_async(author_id, true, true, allow_research)
    elsif !enrich_queued
      ::Books::Authors::EnrichJob.perform_async(author_id, allow_research)
    end
  rescue ::Viaf::Exceptions::RateLimited => e
    paused = e.is_a?(::Viaf::Exceptions::Paused)
    if in_line && !paused
      # The job's own turn, and the pace is busy: an author can need more
      # requests than a minute's pace allows, so the turn goes on shortly,
      # resuming from the suggestions and clusters already stored, rather
      # than going to the back of the line.
      self.class.perform_in(e.retry_after.to_i + rand(RESCHEDULE_JITTER), author_id, refresh, enrich_queued, allow_research, true)
    else
      take_turn(author_id, refresh, enrich_queued, allow_research, not_before: e.retry_after, paused: paused)
    end
  end

  private

  def schedule = (@schedule ||= ::Viaf::Schedule.new)

  # Takes the next start in the line and reschedules for it. The AI step is
  # queued now when VIAF is paused or the start is more than CHAIN_PATIENCE
  # away, and the job carries enrich_queued from then on.
  def take_turn(author_id, refresh, enrich_queued, allow_research, not_before:, paused: false)
    wait = schedule.reserve(not_before: not_before)
    hand_off = !enrich_queued && (paused || wait > CHAIN_PATIENCE)
    ::Books::Authors::EnrichJob.perform_async(author_id, allow_research) if hand_off
    self.class.perform_in(wait + rand(RESCHEDULE_JITTER), author_id, refresh, enrich_queued || hand_off, allow_research, true)
  end
end
