# frozen_string_literal: true

module Games
  module Igdb
    module Search
      class FranchiseSearch < BaseSearch
        def endpoint
          "franchises"
        end

        def default_fields
          %w[name slug games]
        end
      end
    end
  end
end
