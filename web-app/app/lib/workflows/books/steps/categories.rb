# frozen_string_literal: true

# The categories step of the book workflows: Categories::Judge decides the
# book's genres, subjects, locations and audience (and writes its
# books.categories ledger rows). A failed row raises, so the coordinator
# retries it.
#
# Run options read: "context", "label", "book_facts_researched" and
# "force_research" (read only in books.book_categorize: in
# books.book_enrichment that option belongs to book_facts). Research is not
# allowed when book_facts or categorize already researched this book in the
# same run (or the option says it did): at most one research call per book per
# run.
module Workflows
  module Books
    module Steps
      class Categories
        include JudgeOptions

        def call(step:, run:, target:)
          result = ::Services::Books::Categories::Judge.call(
            book: target,
            context: context_for(run),
            label: run.options["label"],
            research_allowed: !(run.options["book_facts_researched"] || researched_in_run?(run, %w[book_facts categorize])),
            force_research: (run.workflow == "books.book_categorize") && run.options.fetch("force_research", false)
          )
          raise StandardError, "Category judging failed for book #{target.id}: #{Array(result.errors).join("; ")}" unless result.success?

          rows = result.data[:enrichments]
          last = rows.last
          label = last && (last.reason.presence || last.outcome)
          Workflows::Outcome.succeeded(label.to_s, {"enrichment_ids" => rows.map(&:id), "applied" => result.data[:applied]})
        end
      end
    end
  end
end
