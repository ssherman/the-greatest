# frozen_string_literal: true

module Services
  module Books
    module Categorize
      # The origin backfill. Picks the books still needing an origin judgment
      # and plans a books.book_categorize run for each, SPACING seconds after
      # the one before (Wikimedia's pace of one request a second, with room for
      # the several requests a book's evidence takes).
      #
      # A book is done when its latest books.origin row ran the current prompt
      # version, did not fail or skip, and did not defer its research (a deferred
      # book counts as done while categorize_backfill_research_daily_cap is 0, since
      # nothing could change its outcome). Books
      # with a running books.book_enrichment run are left out: that import's
      # categorize step judges them. Order: ranked books by rank, then books
      # with no real country (none, or placeholders only), then the rest; ties
      # by id. Everything is one SQL relation, so no id list over the catalog
      # is built in Ruby.
      class Backfill
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        SPACING = 8
        BATCH = 500
        SCOPE = "origin_only"

        def self.call(scope:, limit:, label:, book_ids: nil)
          new(scope: scope, limit: limit, label: label, book_ids: book_ids).call
        end

        def self.refusal(scope)
          "scope #{scope} arrives with stage 3 (categories); use #{SCOPE}" unless scope == SCOPE
        end

        def self.candidates(scope: SCOPE, book_ids: nil)
          raise ArgumentError, refusal(scope) if refusal(scope)

          relation = ::Books::Book.where("NOT EXISTS (#{done_rows.to_sql})").where("NOT EXISTS (#{importing_runs.to_sql})")
          relation = relation.where(id: book_ids) if book_ids
          configuration = ::Books::RankingConfiguration.default_primary
          rank_join = ActiveRecord::Base.sanitize_sql_array([
            "LEFT JOIN ranked_items ON ranked_items.item_type = 'Books::Book' " \
            "AND ranked_items.item_id = books_books.id AND ranked_items.ranking_configuration_id = ?",
            configuration&.id
          ])
          no_real_country = ActiveRecord::Base.sanitize_sql_array([
            "NOT EXISTS (SELECT 1 FROM books_book_countries bc JOIN books_countries c ON c.id = bc.country_id " \
            "WHERE bc.book_id = books_books.id AND lower(c.name) NOT IN (?))",
            ::Services::Books::CountryLookup::PLACEHOLDERS
          ])
          relation.joins(rank_join).order(Arel.sql(
            "CASE WHEN ranked_items.rank IS NOT NULL THEN 0 WHEN #{no_real_country} THEN 1 ELSE 2 END, " \
            "ranked_items.rank ASC NULLS LAST, books_books.id ASC"
          ))
        end

        # Correlated on books_books.id (NOT EXISTS anti-joins, not NOT IN).
        def self.done_rows
          rows = Enrichment.where(enrichable_type: "Books::Book", kind: Origin::Judge::KIND)
            .where("enrichments.enrichable_id = books_books.id")
            .where("NOT EXISTS (SELECT 1 FROM enrichments newer WHERE newer.enrichable_type = enrichments.enrichable_type " \
              "AND newer.enrichable_id = enrichments.enrichable_id AND newer.kind = enrichments.kind AND newer.id > enrichments.id)")
            .where("enrichments.facts->>'prompt_version' = ?", Ai::Tasks::Books::BookOriginTask::PROMPT_VERSION.to_s)
            .where.not(outcome: [:failed, :skipped])
            .select("1")
          # A deferred book waits for research, which the cap at 0 never grants.
          # Read at call time so raising the cap makes them candidates again.
          if Rails.application.config.x.ai.categorize_backfill_research_daily_cap.to_i > 0
            rows = rows.where("enrichments.facts->>'deferred_research' IS DISTINCT FROM 'true'")
          end
          rows
        end

        def self.importing_runs
          ::WorkflowRun.running.where(workflow: ::Workflows::Books::BookEnrichment.workflow, enrichable_type: "Books::Book")
            .where("workflow_runs.enrichable_id = books_books.id").select("1")
        end

        def initialize(scope:, limit:, label:, book_ids:)
          @scope = scope
          @limit = limit
          @label = label
          @book_ids = book_ids
        end

        def call
          refusal = self.class.refusal(@scope)
          return Result.new(success?: false, data: nil, errors: [refusal]) if refusal

          relation = self.class.candidates(scope: @scope, book_ids: @book_ids)
          relation = relation.limit(@limit) if @limit
          planned = 0
          reused = 0
          fresh = 0
          first_slot = first_slot_time
          relation.pluck(:id).each_slice(BATCH) do |ids|
            books = ::Books::Book.where(id: ids).index_by(&:id)
            running = running_book_ids(ids)
            ids.each do |id|
              # Merged or deleted since the pluck: not planned, not counted.
              next unless (book = books[id])

              # A reused run keeps its old slot (the Planner ignores start_after for
              # it), so only books that get a new run advance the slot counter.
              reuse = running.include?(id)
              ActiveRecord::Base.transaction do
                ::Workflows::Books::BookCategorize.start(
                  book, initiated_by: "backfill",
                  options: {"context" => "backfill", "label" => @label},
                  start_after: first_slot + (fresh * SPACING).seconds
                )
              end
              reused += 1 if reuse
              fresh += 1 unless reuse
              planned += 1
            end
          end

          Result.new(success?: true, errors: [], data: {planned: planned, reused: reused, done_at: first_slot + (fresh * SPACING).seconds})
        end

        private

        # A planning job re-run mid-plan would otherwise lay its slots over the
        # earlier run's: start after the latest evidence step still waiting.
        def first_slot_time
          now = Time.current
          latest = ::WorkflowStep.joins(:run)
            .merge(::WorkflowRun.running.where(workflow: ::Workflows::Books::BookCategorize.workflow))
            .where(key: "evidence").maximum(:run_after)
          return now unless latest && latest > now

          latest + SPACING.seconds
        end

        def running_book_ids(ids)
          ::WorkflowRun.running.where(workflow: ::Workflows::Books::BookCategorize.workflow, enrichable_type: "Books::Book", enrichable_id: ids)
            .pluck(:enrichable_id).to_set
        end
      end
    end
  end
end
