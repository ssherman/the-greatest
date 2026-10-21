# frozen_string_literal: true

# A shim for messages already in Sidekiq when the author workflow shipped
# (spec §11 step 1). It used to run the Wikidata step and chain the next one;
# the chain now lives in Workflows::Books::AuthorEnrichment, so an old message
# plans a run from the start instead. The old arguments map to run options:
# refresh stays refresh, and via_viaf (the forced hop after a VIAF match, which
# the workflow plans itself) counts as a forced run; allow_research carries
# over. An author who already has an active run is reused by `start`, which is
# the "does nothing" an in-flight message should get. Nothing enqueues this job
# any more; Task 14 deletes it once Sidekiq holds no more of its messages.
class Books::Authors::WikidataJob
  include Sidekiq::Job

  sidekiq_options queue: :author_chain, retry: 3

  def perform(author_id, refresh = false, via_viaf = false, allow_research = true)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    ::Workflows::Books::AuthorEnrichment.start(author, initiated_by: "legacy_job",
      options: {refresh: refresh || via_viaf, allow_research: allow_research})
  end
end
