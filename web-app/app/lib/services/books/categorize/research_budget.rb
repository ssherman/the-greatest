# frozen_string_literal: true

module Services
  module Books
    module Categorize
      # Whether one more research call is allowed today. The backfill (origin and
      # categories rows alike) spends its own cap so it never starves imports of
      # web searches; imports and admin runs share research_daily_cap.
      class ResearchBudget
        BACKFILL_KINDS = %w[books.origin books.categories].freeze

        def self.permitted?(context:)
          if context == "backfill"
            used = Enrichment.research.today.where(kind: BACKFILL_KINDS).where("facts->>'context' = 'backfill'").count
            used < Rails.application.config.x.ai.categorize_backfill_research_daily_cap
          else
            Enrichment.against_research_cap.count < Rails.application.config.x.ai.research_daily_cap
          end
        end
      end
    end
  end
end
