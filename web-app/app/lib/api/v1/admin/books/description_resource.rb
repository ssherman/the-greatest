# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # A description as an admin API client sees it. Key order here IS the
        # order in config/api/v1/admin_openapi.yaml.
        class DescriptionResource
          def initialize(description)
            @description = description
          end

          def to_h
            {
              id: @description.id,
              kind: @description.kind,
              locale: @description.locale,
              rank: @description.rank,
              source: @description.source,
              source_name: @description.source_name,
              source_url: @description.source_url,
              license: @description.license,
              content: @description.content,
              retrieved_at: @description.retrieved_at,
              created_at: @description.created_at,
              updated_at: @description.updated_at
            }
          end
        end
      end
    end
  end
end
