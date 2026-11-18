# frozen_string_literal: true

module Api
  module V1
    module Admin
      # One claimed queue item as an agent sees it. The payload is built here, once per item, from the
      # type's own payload(record). Key order is the order in config/api/v1/admin_openapi.yaml.
      class EnrichmentItemResource
        def initialize(row, type)
          @row = row
          @type = type
        end

        def to_h
          {id: @row.id, kind: @row.kind, reason: @row.reason, attempts: @row.attempts, payload: @type.payload(@row.enrichable)}
        end
      end
    end
  end
end
