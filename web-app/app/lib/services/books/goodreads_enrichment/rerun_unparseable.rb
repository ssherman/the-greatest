# frozen_string_literal: true

module Services
  module Books
    module GoodreadsEnrichment
      # Starts a fresh books.book_enrichment run for books whose latest run's
      # goodreads step ended "unparseable": Goodreads served a page the parser
      # could not read, so the book missed out. Run it after a parser fix. The
      # new run's step re-reads a stored unparseable search under the new
      # parser before fetching (Steps::Goodreads#cached_search).
      #
      # Only the latest run per book counts, so a book that has since matched
      # (or missed for another reason) is not run again, and a book with a run
      # still going is left to it. At most `limit` books per call, oldest miss
      # first: every started run joins the Goodreads fetch line.
      #
      # The new run is a whole run, carrying the old one's options: book_facts
      # (the AI step) and amazon run again too. That is the point when Goodreads
      # now matches, since both use the page; for a book that misses again it
      # costs one more AI and Amazon pass, which is why each call is limited.
      class RerunUnparseable
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        WORKFLOW = "books.book_enrichment"
        INITIATED_BY = "goodreads_unparseable_rerun"

        LATEST_RUN_SQL = <<~SQL.squish
          NOT EXISTS (
            SELECT 1 FROM workflow_runs newer
            WHERE newer.workflow = workflow_runs.workflow AND newer.enrichable_type = workflow_runs.enrichable_type
              AND newer.enrichable_id = workflow_runs.enrichable_id AND newer.id > workflow_runs.id
          )
        SQL

        def self.call(limit:) = new(limit: limit).call

        def initialize(limit:)
          @limit = limit
        end

        def call
          total = eligible.count
          runs = eligible.order(:created_at, :id).limit(@limit).to_a
          books = ::Books::Book.where(id: runs.map(&:enrichable_id)).index_by(&:id)
          started = runs.count do |run|
            book = books[run.enrichable_id]
            next false unless book

            ::Workflows::Books::BookEnrichment.start(book, initiated_by: initiated_by,
              author_names: Array(run.options["author_names"]), options: run.options.except("author_names"))
            true
          end
          Result.new(success?: true, data: {started: started, remaining: total - started}, errors: [])
        end

        private

        # The goodreads steps whose book gets a new run (RerunFailed picks
        # another set), and the initiated_by the new runs carry.
        def goodreads_steps = WorkflowStep.where(key: "goodreads", outcome: "unparseable")

        def initiated_by = INITIATED_BY

        # The latest finished book run of each existing book, where its
        # goodreads step is one of goodreads_steps.
        def eligible
          WorkflowRun.where(workflow: WORKFLOW, enrichable_type: "Books::Book").where.not(status: :running)
            .where(LATEST_RUN_SQL)
            .where(id: goodreads_steps.select(:workflow_run_id))
            .where(enrichable_id: ::Books::Book.select(:id))
        end
      end
    end
  end
end
