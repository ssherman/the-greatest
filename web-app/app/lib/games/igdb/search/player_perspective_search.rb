# frozen_string_literal: true

module Games
  module Igdb
    module Search
      class PlayerPerspectiveSearch < BaseSearch
        def endpoint
          "player_perspectives"
        end

        def default_fields
          %w[name slug]
        end
      end
    end
  end
end
