# frozen_string_literal: true

# The categorize step of the book workflows: Origin::Judge decides the book's
# origin country (and writes its books.origin ledger rows). A failed row raises,
# so the coordinator retries it.
#
# Run options read: "context" (default "import" in books.book_enrichment,
# "backfill" otherwise), "label", "force_judge", and "force_research" (read only
# in books.book_categorize: in books.book_enrichment that option belongs to
# book_facts). Research is not allowed when book_facts already researched this
# book in the same run: that step spent the day's research cap on it.
module Workflows
  module Books
    module Steps
      class Categorize
        def call(step:, run:, target:)
          result = ::Services::Books::Origin::Judge.call(
            book: target,
            context: run.options["context"] || ((run.workflow == "books.book_enrichment") ? "import" : "backfill"),
            label: run.options["label"],
            research_allowed: !book_facts_researched?(run),
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

        def book_facts_researched?(run)
          step = run.steps.find_by(key: "book_facts")
          return false if step.nil?

          Enrichment.where(workflow_step_id: step.id, mode: :research).exists?
        end
      end
    end
  end
end
