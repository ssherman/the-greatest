# frozen_string_literal: true

module Games
  module Igdb
    module Search
      class PlatformSearch < BaseSearch
        def endpoint
          "platforms"
        end

        def default_fields
          %w[name slug abbreviation generation platform_family]
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

        def by_family(family_id, **opts)
          fields = opts.delete(:fields) || default_fields
          limit = opts.delete(:limit) || 10
          offset = opts.delete(:offset)
          sort = opts.delete(:sort)

          query = Query.new
            .fields(*fields)
            .where(platform_family: family_id)
            .limit(limit)
          query = query.sort(*sort) if sort
          query = query.offset(offset) if offset
          execute(query)
        end
      end
    end
  end
end
