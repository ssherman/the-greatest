# frozen_string_literal: true

module Games
  module Igdb
    module Search
      class CompanySearch < BaseSearch
        def endpoint
          "companies"
        end

        def default_fields
          %w[name slug description country logo developed published]
        end

        def search_by_name(name, **opts)
          fields = opts.delete(:fields) || default_fields
          limit = opts.delete(:limit) || 10
          offset = opts.delete(:offset)

          query = Query.new
            .fields(*fields)
            .search(name)
            .limit(limit)
          query = query.offset(offset) if offset
          execute(query)
        end

        def find_with_details(id)
          validate_id!(id)
          detail_fields = %w[
            name slug description country url start_date
            logo.image_id logo.url
            developed.name developed.slug
            published.name published.slug
          ]

          query = Query.new
            .fields(*detail_fields)
            .where(id: id)
          execute(query)
        end
      end
    end
  end
end
