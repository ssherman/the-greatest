# frozen_string_literal: true

module Games
  module Igdb
    module Search
      class ThemeSearch < BaseSearch
        def endpoint
          "themes"
        end

        def default_fields
          %w[name slug]
        end
      end
    end
  end
end
