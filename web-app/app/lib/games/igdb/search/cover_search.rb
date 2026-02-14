# frozen_string_literal: true

module Games
  module Igdb
    module Search
      class CoverSearch < BaseSearch
        SIZE_THUMB = "t_thumb"
        SIZE_COVER_SMALL = "t_cover_small"
        SIZE_COVER_BIG = "t_cover_big"
        SIZE_720P = "t_720p"
        SIZE_1080P = "t_1080p"

        IMAGE_BASE_URL = "https://images.igdb.com/igdb/image/upload"

        def endpoint
          "covers"
        end

        def default_fields
          %w[image_id url width height game]
        end

        def find_by_game_id(game_id)
          validate_id!(game_id)
          query = Query.new
            .fields(:image_id, :url, :width, :height, :game)
            .where(game: game_id)
          execute(query)
        end

        def find_by_game_ids(game_ids)
          game_ids.each { |id| validate_id!(id) }
          query = Query.new
            .fields(:image_id, :url, :width, :height, :game)
            .where(game: game_ids)
            .limit(game_ids.size)
          execute(query)
        end

        def image_url(image_id, size: SIZE_COVER_BIG)
          "#{IMAGE_BASE_URL}/#{size}/#{image_id}.jpg"
        end
      end
    end
  end
end
