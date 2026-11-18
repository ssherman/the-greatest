# frozen_string_literal: true

module Services
  module Books
    module QueueTypes
      # SQL for "the paid research run gave up on this record". A research skip
      # (budget gone, no search) leaves the record unresearched, so a queue type
      # keeps offering it to an agent until a newer row of the kind replaces the
      # skip. Only the newest row of the kind counts.
      module ResearchSkip
        # An EXISTS fragment correlated on <record_class.table_name>.id.
        def self.latest_sql(record_class, kind)
          ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, record_class.polymorphic_name, kind, ::Enrichment.modes.fetch("research"), ::Enrichment.outcomes.fetch("skipped")])
            EXISTS (
              SELECT 1 FROM enrichments newest
              WHERE newest.id = (
                SELECT latest.id FROM enrichments latest
                WHERE latest.enrichable_type = ? AND latest.enrichable_id = #{record_class.table_name}.id AND latest.kind = ?
                ORDER BY latest.id DESC LIMIT 1
              ) AND newest.mode = ? AND newest.outcome = ?
            )
          SQL
        end
      end
    end
  end
end
