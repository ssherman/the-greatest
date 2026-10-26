# frozen_string_literal: true

# The AI step of the book workflow: EnrichBook, as Books::EnrichBookJob ran it.
# A failed run raises, so the coordinator retries it as the job's Sidekiq
# retries did. "author_names" lets the importer enrich a brand-new book before
# it has book_authors rows; the service falls back to book.authors when empty.
module Workflows
  module Books
    module Steps
      class BookFacts
        def call(step:, run:, target:)
          result = ::Services::Books::EnrichBook.call(
            book: target,
            force_research: run.options.fetch("force_research", false),
            author_names: Array(run.options.fetch("author_names", [])),
            goodreads_page: goodreads_page(run)
          )
          raise StandardError, "Enrichment failed for book #{target.id}: #{result.errors.join("; ")}" unless result.success?

          Workflows::Outcome.succeeded("done")
        end

        private

        # The page the goodreads step matched, or nil: no step (a version-1
        # run), skipped, failed, unmatched, or a page row since deleted.
        def goodreads_page(run)
          step = run.steps.find_by(key: "goodreads")
          return nil unless step&.succeeded? && step.result&.dig("matched")

          ::Books::GoodreadsPage.find_by(id: step.result["page_id"])
        end
      end
    end
  end
end
