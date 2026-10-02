# frozen_string_literal: true

module Api
  module V1
    module Books
      # Root-anchored superclass: inside Api::V1::Books a bare BaseController
      # is this class itself.
      class BaseController < ::Api::V1::BaseController
        require_scope "books:read"

        private

        # The configuration id from the PATH only. params[] merges the query
        # string, and ?ranking_configuration_id= would otherwise turn the bare
        # index into the nested one and skip the route's digits-only constraint.
        def nested_configuration_id
          request.path_parameters[:ranking_configuration_id]
        end

        # The configuration an index reads: the one named in the path when the
        # request came in under /ranking_configurations/:ranking_configuration_id,
        # else the site's primary (nil when there is none yet). Only global,
        # unarchived book configurations are addressable -- a member's own,
        # shared or not, an archived one, or the authors configuration is a 404
        # (spec D3). Runs before Api::Page parses the page params, so a missing
        # parent is a 404 even when the page is also bad.
        #
        # This is the *books* configuration -- the authors ranking has its own
        # primary and must not use this helper.
        def ranking_configuration
          if (id = nested_configuration_id)
            ::Books::RankingConfiguration.global.active.find(id)
          else
            ::Books::RankingConfiguration.default_primary
          end
        end

        # The base path for a collection's `links`: the nested form when the
        # request came in nested, so a client paging a configuration's books
        # stays on that configuration.
        def collection_path(suffix)
          if (id = nested_configuration_id)
            "/api/v1/ranking_configurations/#{id}/#{suffix}"
          else
            "/api/v1/#{suffix}"
          end
        end

        # The list items the API serves and counts: rows whose listable is a
        # Books::Book that exists -- importers can leave listable_id null,
        # write another listable_type, or leave an id whose book is gone.
        # Filtering in the relation rather than in the serializer keeps
        # total_count, per_page and the rows consistent (spec D6), and
        # item_counts_for uses the same predicate so a list's item_count
        # always equals its /items total_count.
        def book_items(scope)
          scope.by_listable_type("Books::Book").where(listable_id: ::Books::Book.select(:id))
        end

        # {list_id => item_count} in one grouped query for a page of lists, and
        # none at all for an empty page. A list with no served items has no
        # key -- callers fetch with a default of 0.
        def item_counts_for(list_ids)
          return {} if list_ids.empty?

          book_items(::ListItem.where(list_id: list_ids)).group(:list_id).count
        end
      end
    end
  end
end
