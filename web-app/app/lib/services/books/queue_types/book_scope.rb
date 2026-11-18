# frozen_string_literal: true

module Services
  module Books
    module QueueTypes
      # What every books queue type shares: which books are offered at all, how
      # they are ordered (by rank, unranked last) and how to read what was
      # already tried. `extend` it from a type.
      module BookScope
        UNRANKED_PRIORITY = 1_000_000

        # LEFT JOIN on the default primary ranking, as Categorize::Backfill does.
        def ranked_join_sql
          ActiveRecord::Base.sanitize_sql_array([
            "LEFT JOIN ranked_items ON ranked_items.item_type = 'Books::Book' " \
            "AND ranked_items.item_id = books_books.id AND ranked_items.ranking_configuration_id = ?",
            ::Books::RankingConfiguration.default_primary&.id
          ])
        end

        # Titled books with no running import or categorize run (those judge the
        # book themselves), joined to the rank. "ranked" keeps only ranked books.
        def base_relation(scope:)
          raise ArgumentError, "unknown scope: #{scope.inspect}" unless Services::EnrichmentQueue::Type::SCOPES.include?(scope.to_s)

          relation = ::Books::Book
            .where("books_books.title IS NOT NULL AND btrim(books_books.title) <> ''")
            .where("NOT EXISTS (#{running_runs.to_sql})")
            .joins(ranked_join_sql)
          relation = relation.where("ranked_items.rank IS NOT NULL") if scope.to_s == "ranked"
          relation
        end

        def priority_sql = "COALESCE(ranked_items.rank, #{UNRANKED_PRIORITY})"

        # The record's latest ledger row of this kind, whatever its mode.
        def tried(book, kind)
          row = book.enrichments.where(kind: kind).order(:id).last
          return nil unless row

          {"mode" => row.mode, "outcome" => row.outcome, "reason" => row.reason, "confidence" => row.confidence,
           "answer" => row.facts["answer"]}
        end

        private

        def running_runs
          workflows = [::Workflows::Books::BookEnrichment.workflow, ::Workflows::Books::BookCategorize.workflow]
          ::WorkflowRun.running.where(workflow: workflows, enrichable_type: "Books::Book")
            .where("workflow_runs.enrichable_id = books_books.id").select("1")
        end
      end
    end
  end
end
