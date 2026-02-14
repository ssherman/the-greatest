# frozen_string_literal: true

module Games
  module Igdb
    module Search
      class KeywordSearch < BaseSearch
        def endpoint
          "keywords"
        end

        def default_fields
          %w[name slug]
        end
      end
    end
  end
end
