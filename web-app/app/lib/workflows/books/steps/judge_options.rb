# frozen_string_literal: true

# What the categorize and categories steps share: the judge context a run
# implies and the "was this book already researched in this run" check.
#
# In books.book_enrichment the context is "import" only for the initiators in
# IMPORT_INITIATORS, which create new books; the bulk re-runs over existing
# books (goodreads_rebuild, goodreads_unparseable_rerun) use "backfill" so they
# spend the backfill budget, not the import research cap.
module Workflows
  module Books
    module Steps
      module JudgeOptions
        # Real new-import initiators of books.book_enrichment: the book importer
        # and the Goodreads promote step.
        IMPORT_INITIATORS = %w[importer goodreads_promote].freeze

        private

        def context_for(run)
          return run.options["context"] if run.options["context"]
          return "backfill" unless run.workflow == "books.book_enrichment"

          IMPORT_INITIATORS.include?(run.initiated_by) ? "import" : "backfill"
        end

        # True when a research-mode Enrichment exists for any of the run's steps
        # named in keys.
        def researched_in_run?(run, keys)
          step_ids = run.steps.where(key: keys).pluck(:id)
          return false if step_ids.empty?

          Enrichment.where(workflow_step_id: step_ids, mode: :research).exists?
        end
      end
    end
  end
end
