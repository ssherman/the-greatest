# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Keeps the fixed books flowing through the normal new-book enrichment
      # (Goodreads page, author chains, book AI, Amazon) without starving other
      # books of Goodreads fetches: at most `in_flight` rebuild books wait for
      # their Goodreads fetch at once, and the 10-minute top-up job starts more as
      # those finish. The most-listed books go first. A fix is picked up once: a
      # book with any enrichment run created since its fix was applied is done.
      #
      # While the fetch gate is blocked Goodreads has refused us, so no new book
      # joins until it clears.
      class QueueEnrichment
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        INITIATED_BY = "goodreads_rebuild"
        WORKFLOW = "books.book_enrichment"

        # Joins each applied fix to its book (which must still exist) and to how
        # many members list that book.
        JOINS_SQL = <<~SQL.squish
          INNER JOIN books_books ON books_books.id = (books_repair_verdicts.payload->>'book_id')::bigint
          LEFT JOIN (
            SELECT listable_id, COUNT(*) AS item_count FROM user_list_items
            WHERE listable_type = 'Books::Book' GROUP BY listable_id
          ) list_counts ON list_counts.listable_id = books_books.id
        SQL

        # Not enriched since the fix, and not in the middle of an older run: starting
        # a book that already has a running run returns that run untouched, so
        # such a book would be picked again every round and never start.
        NOT_ENRICHED_SQL = <<~SQL.squish
          NOT EXISTS (
            SELECT 1 FROM workflow_runs
            WHERE workflow_runs.workflow = :workflow AND workflow_runs.enrichable_type = 'Books::Book'
              AND workflow_runs.enrichable_id = books_books.id
              AND (workflow_runs.created_at >= books_repair_verdicts.applied_at OR workflow_runs.status = :running)
          )
        SQL

        def self.call(in_flight:) = new(in_flight: in_flight).call

        def initialize(in_flight:)
          @in_flight = in_flight
        end

        def call
          current = running.count
          return result(0, current) if ::Books::Goodreads::FetchGate.new.blocked?

          verdicts = eligible.limit([@in_flight - current, 0].max).to_a
          verdicts.each { |verdict| start(verdict) }
          result(verdicts.size, current + verdicts.size)
        end

        private

        # Runs still waiting for their Goodreads fetch. The step is finished once
        # it has released the steps behind it (success, skip or failure alike).
        def running
          WorkflowRun.running.where(workflow: WORKFLOW, initiated_by: INITIATED_BY)
            .where(id: WorkflowStep.where(key: "goodreads", released_at: nil).select(:workflow_run_id))
        end

        # Applied fixes whose book has had no enrichment run since the fix,
        # most-listed book first.
        def eligible
          ::Books::RepairVerdict.fix_identity.where.not(applied_at: nil)
            .where("books_repair_verdicts.subject_key LIKE 'rebuild:%'")
            .joins(JOINS_SQL)
            .where(NOT_ENRICHED_SQL, workflow: WORKFLOW, running: WorkflowRun.statuses.fetch("running"))
            .reorder(Arel.sql("COALESCE(list_counts.item_count, 0) DESC, books_books.id"))
        end

        def start(verdict)
          payload = verdict.payload
          ::Workflows::Books::BookEnrichment.start(::Books::Book.find(payload["book_id"]), initiated_by: INITIATED_BY,
            new_author_ids: payload["created_author_ids"] || [], author_names: payload["author_names"])
        end

        def result(started, in_flight)
          Result.new(success?: true, data: {started: started, in_flight: in_flight, waiting: eligible.count}, errors: [])
        end
      end
    end
  end
end
