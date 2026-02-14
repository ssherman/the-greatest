# frozen_string_literal: true

module Games
  module Igdb
    module Search
      class GenreSearch < BaseSearch
        def endpoint
          "genres"
        end

        def default_fields
          %w[name slug]
        end
      end
    end
  end
end
