# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # One row of the repair-verdict review queue. Key order is the order in config/api/v1/admin_openapi.yaml.
        # Root-anchor every ::Books:: reference in this namespace.
        class RepairVerdictResource
          def initialize(verdict)
            @verdict = verdict
          end

          def to_h
            {
              id: @verdict.id,
              kind: @verdict.kind,
              status: @verdict.status,
              decided_by: @verdict.decided_by,
              confidence: @verdict.confidence,
              summary: @verdict.summary,
              reason: @verdict.reason,
              guess: @verdict.payload["guess"] == true,
              reviewed_at: @verdict.reviewed_at,
              applied_at: @verdict.applied_at,
              created_at: @verdict.created_at
            }
          end
        end
      end
    end
  end
end
