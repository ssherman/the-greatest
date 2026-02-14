# frozen_string_literal: true

module Games
  module Igdb
    module Search
      class GameModeSearch < BaseSearch
        def endpoint
          "game_modes"
        end

        def default_fields
          %w[name slug]
        end
      end
    end
  end
end
