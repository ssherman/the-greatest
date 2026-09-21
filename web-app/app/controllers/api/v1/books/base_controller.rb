# frozen_string_literal: true

module Api
  module V1
    module Books
      # Root-anchored superclass: inside Api::V1::Books a bare BaseController
      # is this class itself.
      class BaseController < ::Api::V1::BaseController
        require_scope "books:read"

        private

        # The configuration an index reads: the one named in the path when the
        # request came in under /ranking_configurations/:ranking_configuration_id,
        # else the site's primary (nil when there is none yet). Only global,
        # unarchived book configurations are addressable -- a member's own,
        # shared or not, an archived one, or the authors configuration is a 404
        # (spec D3). Runs before Api::Page parses the page params, so a missing
        # parent is a 404 even when the page is also bad.
        def ranking_configuration
          if params[:ranking_configuration_id]
            ::Books::RankingConfiguration.global.active.find(params[:ranking_configuration_id])
          else
            ::Books::RankingConfiguration.default_primary
          end
        end

        # The base path for a collection's `links`: the nested form when the
        # request came in nested, so a client paging a configuration's books
        # stays on that configuration.
        def collection_path(suffix)
          if params[:ranking_configuration_id]
            "/api/v1/ranking_configurations/#{params[:ranking_configuration_id]}/#{suffix}"
          else
            "/api/v1/#{suffix}"
          end
        end
      end
    end
  end
end
