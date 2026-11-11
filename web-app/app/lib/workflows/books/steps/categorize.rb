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
# The context rules (IMPORT_INITIATORS) live in Steps::JudgeOptions.
module Workflows
  module Books
    module Steps
      class Categorize
        include JudgeOptions

        def call(step:, run:, target:)
          result = ::Services::Books::Origin::Judge.call(
            book: target,
            context: context_for(run),
            label: run.options["label"],
            research_allowed: !(run.options["book_facts_researched"] || researched_in_run?(run, %w[book_facts])),
            force: run.options.fetch("force_judge", false),
            force_research: (run.workflow == "books.book_categorize") && run.options.fetch("force_research", false)
          )
          raise StandardError, "Origin judging failed for book #{target.id}: #{Array(result.errors).join("; ")}" unless result.success?

          rows = result.data[:enrichments]
          last = rows.last
          label = last && (last.reason.presence || last.outcome)
          Workflows::Outcome.succeeded(label.to_s, {"enrichment_ids" => rows.map(&:id), "applied" => result.data[:applied]})
        end
      end
    end
  end
end
