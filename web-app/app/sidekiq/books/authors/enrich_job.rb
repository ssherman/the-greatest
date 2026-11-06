# frozen_string_literal: true

# A shim for messages already in Sidekiq when the author workflow shipped
# (spec §11 step 1). An old message plans an author run with only the AI step
# (author_facts), so the AI call goes through the workflow's lease, retries and
# ledger link rather than running beside an active run: the old VIAF step queued
# this job and kept its own turn, so both can be in flight at deploy, and the
# ViafJob shim's run would then pay for the AI step a second time. An author who
# already has an active run is reused by `start`, and that run's author_facts
# does the AI work and the hand-off. Nothing enqueues this job any more; Task 14
# deletes it.
#
# hand_off stays here until then: the author workflow's author_facts step calls
# it (on_terminal) for books deferred under the old system, after a successful
# run or once its attempts are spent.
class Books::Authors::EnrichJob
  include Sidekiq::Job

  sidekiq_options queue: :author_chain, retry: 3

  def self.hand_off(author_id)
    author = ::Books::Author.find_by(id: author_id)
    return if author.nil?

    ids = ::Services::Books::DeferredEnrichment.waiting_book_ids(author)
    # A book with a running book run (Workflows::Books::AdoptDeferred plans one
    # for every deferred book) is enriched by that run's book_facts step. Handing
    # it on as well would pay for the AI enrichment twice. Only books that have
    # no run yet are this hand-off's (spec section 11). Task 14 deletes it.
    owned = ::WorkflowRun.running.where(workflow: ::Workflows::Books::BookEnrichment.workflow,
      enrichable_type: "Books::Book", enrichable_id: ids).pluck(:enrichable_id)
    (ids - owned).each { |book_id| ::Books::EnrichBookJob.perform_async(book_id) }
  end

  def perform(author_id, allow_research = true)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    ::Workflows::Books::AuthorEnrichment.start(author, initiated_by: "legacy_job",
      options: {allow_research: allow_research, only: ["author_facts"]})
  end
end
