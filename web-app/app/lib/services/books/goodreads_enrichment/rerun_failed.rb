# frozen_string_literal: true

module Services
  module Books
    module GoodreadsEnrichment
      # Starts a fresh books.book_enrichment run for books whose latest run's
      # goodreads step failed: every attempt raised (Goodreads' 503 page, a
      # timeout, the page fetcher down). The 2026-11-03 to 11-06 home-server
      # network outage left about 1,600 of them, and a 503 streak adds a few a
      # day. RerunUnparseable's rules apply unchanged: latest run only, a book
      # with a run going is left to it, oldest first, at most `limit` per call,
      # and the new run is whole, so book_facts and amazon run again too.
      class RerunFailed < RerunUnparseable
        INITIATED_BY = "goodreads_failed_rerun"

        private

        def goodreads_steps = WorkflowStep.where(key: "goodreads", state: :failed)

        def initiated_by = INITIATED_BY
      end
    end
  end
end
