# frozen_string_literal: true

module Services
  module Books
    module QueueTypes
      # What every books author queue type shares: which authors are offered at
      # all and how they are ordered (by rank in the default primary author
      # ranking, unranked last). `extend` it from a type, as BookScope is.
      module AuthorScope
        UNRANKED_PRIORITY = 1_000_000

        def ranked_join_sql
          ActiveRecord::Base.sanitize_sql_array([
            "LEFT JOIN ranked_items ON ranked_items.item_type = 'Books::Author' " \
            "AND ranked_items.item_id = books_authors.id AND ranked_items.ranking_configuration_id = ?",
            ::Books::Authors::RankingConfiguration.default_primary&.id
          ])
        end

        # Real authors (not placeholders) with no running author enrichment run
        # (that run researches the author itself), joined to the rank. "ranked"
        # keeps only ranked authors.
        def base_relation(scope:)
          raise ArgumentError, "unknown scope: #{scope.inspect}" unless Services::EnrichmentQueue::Type::SCOPES.include?(scope.to_s)

          relation = ::Books::Author
            .where(exclude_from_rankings: false)
            .where("NOT EXISTS (#{running_runs.to_sql})")
            .joins(ranked_join_sql)
          relation = relation.where("ranked_items.rank IS NOT NULL") if scope.to_s == "ranked"
          relation
        end

        def priority_sql = "COALESCE(ranked_items.rank, #{UNRANKED_PRIORITY})"

        # Deliberately not base_relation: an author with a running run still
        # needs a priority.
        def priority_for(author)
          ::RankedItem.where(item_type: "Books::Author", item_id: author.id,
            ranking_configuration_id: ::Books::Authors::RankingConfiguration.default_primary&.id).pick(:rank) || UNRANKED_PRIORITY
        end

        private

        def running_runs
          ::WorkflowRun.running.where(workflow: ::Workflows::Books::AuthorEnrichment.workflow, enrichable_type: "Books::Author")
            .where("workflow_runs.enrichable_id = books_authors.id").select("1")
        end
      end
    end
  end
end
