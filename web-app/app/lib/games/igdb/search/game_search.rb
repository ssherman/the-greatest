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

        ALLOWED_GAME_TYPES = "(0,4,8,9,10,11)"

        def search_by_name(name, **opts)
          fields = opts.delete(:fields) || default_fields
          limit = opts.delete(:limit) || 10
          offset = opts.delete(:offset)

          result = primary_search(name, fields, limit, offset)
          return result if results_present?(result)

          result = name_contains_search(name, fields, limit)
          return result if results_present?(result)

          alternative_names_search(name, fields)
        end

        def find_with_details(id)
          validate_id!(id)
          query = Query.new
            .fields(*find_with_details_fields)
            .where(id: id)
          execute(query)
        end

        private

        def find_with_details_fields
          %w[
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
        end

        def primary_search(name, fields, limit, offset)
          query = Query.new
            .fields(*fields)
            .search(name)
            .where("game_type = #{ALLOWED_GAME_TYPES}")
            .limit(limit)
          query = query.offset(offset) if offset
          execute(query)
        end

        def name_contains_search(name, fields, limit)
          escaped = name.gsub('"', '\\"')
          query = Query.new
            .fields(*fields)
            .where("name ~ *\"#{escaped}\"*")
            .where("game_type = #{ALLOWED_GAME_TYPES}")
            .limit(limit)
          execute(query)
        end

        def alternative_names_search(name, fields)
          escaped = name.gsub('"', '\\"')
          alt_query = "fields game; where name ~ *\"#{escaped}\"*; limit 10;"
          alt_result = client.post("alternative_names", alt_query)

          return empty_success unless alt_result[:success] && alt_result[:data]&.any?

          game_ids = alt_result[:data].filter_map { |r| r["game"] }.uniq
          return empty_success if game_ids.empty?

          find_by_ids(game_ids, fields: fields)
        rescue Exceptions::Error => e
          handle_error(e, "alternative_names fallback")
        end

        def results_present?(result)
          result[:success] && result[:data]&.any?
        end

        def empty_success
          {success: true, data: [], errors: [], metadata: {endpoint: endpoint, query: "fallback"}}
        end

        public

        def find_by_slug(slug)
          query = Query.new
            .fields(*find_with_details_fields)
            .where("slug = \"#{slug.gsub('"', '\\"')}\"")
            .limit(1)
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
