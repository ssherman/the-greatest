# frozen_string_literal: true

# The categorize step of the book workflows: Origin::Judge decides the book's
# origin country (and writes its books.origin ledger rows). A failed row raises,
# so the coordinator retries it.
#
# Run options read: "context" (default "import" in books.book_enrichment,
# "backfill" otherwise), "label", "force_judge", and "force_research" (read only
# in books.book_categorize: in books.book_enrichment that option belongs to
# book_facts) and "book_facts_researched" (set by EnrichBookJob on a
# books.book_categorize run after EnrichBook researched). Research is not
# allowed when book_facts already researched this book in the same run (or the
# option says it did): that step spent the day's research cap on it.
#
# In books.book_enrichment the context is "import" only for the initiators in
# IMPORT_INITIATORS, which create new books; the bulk re-runs over existing
# books (goodreads_rebuild, goodreads_unparseable_rerun) use "backfill" so they
# spend the backfill budget, not the import research cap.
module Workflows
  module Books
    module Steps
      class Categorize
        # Real new-import initiators of books.book_enrichment: the book importer
        # and the Goodreads promote step.
        IMPORT_INITIATORS = %w[importer goodreads_promote].freeze

        def call(step:, run:, target:)
          result = ::Services::Books::Origin::Judge.call(
            book: target,
            context: context_for(run),
            label: run.options["label"],
            research_allowed: !(run.options["book_facts_researched"] || book_facts_researched?(run)),
            force: run.options.fetch("force_judge", false),
            force_research: (run.workflow == "books.book_categorize") && run.options.fetch("force_research", false)
          )
          raise StandardError, "Origin judging failed for book #{target.id}: #{Array(result.errors).join("; ")}" unless result.success?

          rows = result.data[:enrichments]
          last = rows.last
          label = last && (last.reason.presence || last.outcome)
          Workflows::Outcome.succeeded(label.to_s, {"enrichment_ids" => rows.map(&:id), "applied" => result.data[:applied]})
        end

        private

        def context_for(run)
          return run.options["context"] if run.options["context"]
          return "backfill" unless run.workflow == "books.book_enrichment"

          IMPORT_INITIATORS.include?(run.initiated_by) ? "import" : "backfill"
        end

        def book_facts_researched?(run)
          step = run.steps.find_by(key: "book_facts")
          return false if step.nil?

          Enrichment.where(workflow_step_id: step.id, mode: :research).exists?
        end
      end
    end
  end
end
