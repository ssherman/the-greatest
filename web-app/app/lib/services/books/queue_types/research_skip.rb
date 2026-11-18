# frozen_string_literal: true

module Services
  module Books
    module QueueTypes
      # SQL for "the paid research run gave up on this record". A research skip
      # (budget gone, no search) leaves the record unresearched, so a queue type
      # keeps offering it to an agent until a newer row of the kind replaces the
      # skip. Only the newest row of the kind counts, and two kinds of row do not
      # count at all, because they left the research owed:
      #
      # - a failed run, which answered nothing. Without this, a paid worker run
      #   that failed would leave its failed ledger row as the newest one;
      # - an agent's answer that applied nothing (held for low confidence, or the
      #   agent did not recognize the record). Categorize::Backfill.done_rows
      #   treats such a row the same way.
      #
      # In both cases the record's queue row is already closed, so nothing hands
      # it out again unless an admin re-queues it; this rule is what lets that
      # re-queued row be claimed instead of being closed as no longer needed.
      module ResearchSkip
        # An EXISTS fragment correlated on <record_class.table_name>.id.
        def self.latest_sql(record_class, kind)
          outcomes = ::Enrichment.outcomes
          modes = ::Enrichment.modes
          ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, record_class.polymorphic_name, kind, outcomes.fetch("failed"), modes.fetch("agent"), outcomes.fetch("applied"), modes.fetch("research"), outcomes.fetch("skipped")])
            EXISTS (
              SELECT 1 FROM enrichments newest
              WHERE newest.id = (
                SELECT latest.id FROM enrichments latest
                WHERE latest.enrichable_type = ? AND latest.enrichable_id = #{record_class.table_name}.id AND latest.kind = ?
                  AND latest.outcome <> ?
                  AND NOT (latest.mode = ? AND latest.outcome <> ?)
                ORDER BY latest.id DESC LIMIT 1
              ) AND newest.mode = ? AND newest.outcome = ?
            )
          SQL
        end
      end
    end
  end
end
