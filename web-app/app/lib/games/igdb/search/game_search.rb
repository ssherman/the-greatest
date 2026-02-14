# frozen_string_literal: true

module Games
  module Igdb
    module Search
      class GameSearch < BaseSearch
        def endpoint
          "games"
        end

        def default_fields
          %w[name slug summary first_release_date rating total_rating
            cover genres platforms game_modes themes keywords
            player_perspectives franchises involved_companies]
        end

        def search_by_name(name, **opts)
          fields = opts.delete(:fields) || default_fields
          limit = opts.delete(:limit) || 10
          offset = opts.delete(:offset)

          query = Query.new
            .fields(*fields)
            .search(name)
            .where("game_type = 0")
            .limit(limit)
          query = query.offset(offset) if offset
          execute(query)
        end

        def find_with_details(id)
          validate_id!(id)
          detail_fields = %w[
            name slug summary storyline first_release_date rating total_rating
            cover.image_id cover.url
            genres.name genres.slug
            platforms.name platforms.slug platforms.abbreviation
            involved_companies.company.name involved_companies.developer involved_companies.publisher
            franchises.name franchises.slug
            themes.name themes.slug
            game_modes.name game_modes.slug
            keywords.name keywords.slug
            player_perspectives.name player_perspectives.slug
          ]

          query = Query.new
            .fields(*detail_fields)
            .where(id: id)
          execute(query)
        end

        def by_platform(platform_id, **opts)
          fields = opts.delete(:fields) || default_fields
          limit = opts.delete(:limit) || 10
          offset = opts.delete(:offset)
          sort = opts.delete(:sort)

          query = Query.new
            .fields(*fields)
            .where(platforms: [platform_id])
            .limit(limit)
          query = query.sort(*sort) if sort
          query = query.offset(offset) if offset
          execute(query)
        end
      end
    end
  end
end
