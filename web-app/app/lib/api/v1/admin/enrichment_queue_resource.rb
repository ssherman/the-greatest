# frozen_string_literal: true

module Api
  module V1
    module Admin
      # One enrichment queue type for the admin API. Key order is the order in config/api/v1/admin_openapi.yaml.
      # The list carries counts; the detail adds the outcome counts of finished items and the type's reference
      # (the answer schema and any closed list an answer must choose from).
      class EnrichmentQueueResource
        def initialize(type, detail: false)
          @type = type
          @detail = detail
        end

        def to_h
          counts = ::Services::EnrichmentQueue::Counts.call(kind: @type.kind)
          row = {type: @type.slug, kind: @type.kind, label: @type.label, version: @type.version, counts: counts[:statuses]}
          return row unless @detail

          row.merge(outcomes: counts[:outcomes], reference: @type.reference)
        end
      end
    end
  end
end
