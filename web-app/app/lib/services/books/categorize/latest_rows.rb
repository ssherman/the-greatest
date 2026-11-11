# frozen_string_literal: true

module Services
  module Books
    module Categorize
      # The newest ledger row of a kind per book (highest id), optionally within
      # one run label. Shared by the origin and categories reports and by the
      # tasks that act on a run's latest answers.
      class LatestRows
        def self.call(kind:, label: nil)
          scope = ::Enrichment.where(kind: kind)
          newer = "SELECT 1 FROM enrichments newer WHERE newer.enrichable_type = enrichments.enrichable_type " \
            "AND newer.enrichable_id = enrichments.enrichable_id AND newer.kind = enrichments.kind " \
            "AND newer.id > enrichments.id"
          if label
            scope = scope.where("enrichments.facts->>'label' = ?", label)
            newer += " AND newer.facts->>'label' = #{::Enrichment.connection.quote(label)}"
          end
          scope.where("NOT EXISTS (#{newer})")
        end
      end
    end
  end
end
