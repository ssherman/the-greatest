# frozen_string_literal: true

# A shim for messages already in Sidekiq when the author workflow shipped
# (spec §11 step 1). The VIAF line logic (Viaf::Schedule turns, pauses,
# CHAIN_PATIENCE) now lives in Workflows::Books::Steps::Viaf, so an old message
# plans a run that starts at the VIAF step. enrich_queued said the old chain had
# already queued the AI step, which is skip_ai_if_ran in the workflow. The
# in_line flag only described the old job's own reschedule and has no meaning
# here, but stays in the signature so a queued message still deserializes. An
# author who already has an active run is reused by `start`. Nothing enqueues
# this job any more; Task 14 deletes it.
class Books::Authors::ViafJob
  include Sidekiq::Job

  sidekiq_options queue: :author_chain, retry: 3

  def perform(author_id, refresh = false, enrich_queued = false, allow_research = true, in_line = false)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    ::Workflows::Books::AuthorEnrichment.start(author, initiated_by: "legacy_job",
      options: {refresh: refresh, allow_research: allow_research, start_at: "viaf", skip_ai_if_ran: enrich_queued})
  end
end
