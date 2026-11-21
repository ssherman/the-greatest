module Services
  module Lists
    module Audits
      # The books lists still waiting for an audit, in the order an agent should
      # take them: never started first, then least recently worked, then heaviest.
      class Queue
        def self.relation
          scope = ::Books::List
            .where(status: %i[active approved], auto_generated_kind: nil)
            .where(<<~SQL.squish, finished: ::ListAudit.statuses[:finished], in_progress: ::ListAudit.statuses[:in_progress], now: Time.current)
              NOT EXISTS (
                SELECT 1 FROM list_audits blocking
                WHERE blocking.list_id = lists.id
                  AND (blocking.status = :finished
                    OR (blocking.status = :in_progress AND blocking.lease_expires_at > :now))
              )
            SQL
            .joins(<<~SQL.squish)
              LEFT JOIN (
                SELECT list_id, MAX(started_at) AS last_started_at
                FROM list_audits
                WHERE status <> #{::ListAudit.statuses[:finished].to_i}
                GROUP BY list_id
              ) past_audits ON past_audits.list_id = lists.id
            SQL

          orders = ["past_audits.last_started_at ASC NULLS FIRST"]
          primary = ::Books::RankingConfiguration.default_primary
          if primary
            scope = scope.joins(
              "LEFT JOIN ranked_lists audit_rl ON audit_rl.list_id = lists.id " \
              "AND audit_rl.ranking_configuration_id = #{primary.id.to_i}"
            )
            orders << "audit_rl.weight DESC NULLS LAST"
          end
          orders << "lists.id ASC"
          scope.order(Arel.sql(orders.join(", ")))
        end

        def self.remaining
          relation.unscope(:order).count
        end
      end
    end
  end
end
