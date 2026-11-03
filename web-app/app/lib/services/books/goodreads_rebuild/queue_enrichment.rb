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
      # A title-only fix kept the book's data, so it has nothing to rebuild and is never queued;
      # a fix without a recorded scope (applied before scopes existed) was a full reset.
      #
      # Books the Goodreads re-import created (and books whose authors it created) join the same queue,
      # after the fixes and under the same cap, once `goodreads_reimport.enrichment` is on.
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
          INNER JOIN books_books ON books_books.id = (books_repair_verdicts.payload->>'%<key>s')::bigint
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

          entries = eligible([@in_flight - current, 0].max)
          entries.each { |entry| start(entry) }
          result(entries.size, current + entries.size)
        end

        private

        # Runs still waiting for their Goodreads fetch. The step is finished once
        # it has released the steps behind it (success, skip or failure alike).
        def running
          WorkflowRun.running.where(workflow: WORKFLOW, initiated_by: INITIATED_BY)
            .where(id: WorkflowStep.where(key: "goodreads", released_at: nil).select(:workflow_run_id))
        end

        # The verdicts that put a book up for enrichment, in the order they are started: the rebuild's
        # fixes first, then (only while the re-import's enrichment gate is open) the books the re-import
        # created and the books whose authors it created. Each: [relation, book id key, how to read the
        # verdict's author names and created author ids].
        def sources
          list = [[::Books::RepairVerdict.fix_identity.where("books_repair_verdicts.subject_key LIKE 'rebuild:%'")
            .where("COALESCE(books_repair_verdicts.payload->>'fix_scope', 'full') = 'full'"), "book_id", :fix]]
          if Rails.configuration.x.goodreads_reimport.enrichment
            list << [::Books::RepairVerdict.reimport_match.approved.current, "created_book_id", :match]
            # Only authors the re-import created: a final noop ("authors already set") leaves the book as it was.
            list << [::Books::RepairVerdict.reimport_author.current
              .where("jsonb_array_length(COALESCE(books_repair_verdicts.payload->'created_author_ids', '[]'::jsonb)) > 0"),
              "book_id", :author]
          end
          list
        end

        # Applied verdicts whose book has had no enrichment run since, most-listed book first within a source.
        def eligible_in(relation, key)
          relation.where.not(applied_at: nil)
            .joins(format(JOINS_SQL, key: key))
            .where(NOT_ENRICHED_SQL, workflow: WORKFLOW, running: WorkflowRun.statuses.fetch("running"))
            .reorder(Arel.sql("COALESCE(list_counts.item_count, 0) DESC, books_books.id"))
        end

        # Up to `limit` entries, one per book, in start order; a book several verdicts name gets all their
        # created authors. Each source loads at most what could still be started, not every eligible row.
        # A created book that was merged away is skipped on purpose: the survivor had its own enrichment.
        def eligible(limit)
          entries = {}
          sources.each do |relation, key, shape|
            break if entries.size >= limit

            eligible_in(relation, key).limit(limit + entries.size).each do |verdict|
              entry = entries[verdict.payload[key]] ||= {book_id: verdict.payload[key], author_names: nil, new_author_ids: []}
              names, ids = names_and_authors(verdict.payload, shape)
              entry[:author_names] ||= names
              entry[:new_author_ids] |= ids
            end
          end
          entries.values.first(limit)
        end

        # Distinct books still eligible, for the "waiting" count; ids only.
        def eligible_count
          sources.flat_map { |relation, key, _| eligible_in(relation, key).pluck(Arel.sql("books_books.id")) }.uniq.size
        end

        def names_and_authors(payload, shape)
          case shape
          when :fix then [payload["author_names"], payload["created_author_ids"] || []]
          when :match then [payload.dig("facts", "author_names"), []]
          else [payload["row_author_names"], payload["created_author_ids"] || []]
          end
        end

        def start(entry)
          ::Workflows::Books::BookEnrichment.start(::Books::Book.find(entry[:book_id]), initiated_by: INITIATED_BY,
            new_author_ids: entry[:new_author_ids], author_names: entry[:author_names])
        end

        def result(started, in_flight)
          Result.new(success?: true, data: {started: started, in_flight: in_flight, waiting: eligible_count}, errors: [])
        end
      end
    end
  end
end
