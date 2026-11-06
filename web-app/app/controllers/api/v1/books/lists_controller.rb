# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/lists                              -- the primary ranking's active lists, heaviest first
      # GET /api/v1/ranking_configurations/:id/lists   -- the same, on the named configuration
      # GET /api/v1/lists/:id                          -- any active list, full shape
      # GET /api/v1/ranking_configurations/:id/lists/:list_id -- the same, its weight on the named configuration
      #
      # weight is a property of the (list, configuration) pair (spec D1): a
      # row carries the weight on the configuration it was read through (the
      # primary when bare) and show answers null off it (D5, D-d).
      #
      # Every model reference is root-anchored. This is the sharp case: inside
      # Api::V1::Books a bare `List` resolves (to ::List, the STI base) while a
      # bare `Books::List` raises NameError -- so it is ::Books::List throughout.
      class ListsController < BaseController
        def index
          configuration = ranking_configuration
          sort = enum_param!(:sort, ::ListsQuery::SORTS)
          query = text_param!(:q, required: false, max_length: 200)
          relation = configuration && ::Books::ListsQuery.call(ranking_configuration: configuration, sort: sort || "weight", query: query)

          # Only what the client sent rides on the links, so a bare request's
          # links stay what they were.
          render_page(relation, path: collection_path("lists"), query: {sort: sort, q: query}.compact) do |ranked_lists|
            counts = item_counts_for(ranked_lists.map(&:list_id))
            ranked_lists.map do |ranked_list|
              ListResource.new(ranked_list.list, params: {weight: ranked_list.weight, item_count: counts.fetch(ranked_list.list_id, 0)}).to_h
            end
          end
        end

        def show
          # Resolved first, so a bad configuration is a 404 before the list.
          configuration = ranking_configuration
          list = ::Books::List.active.find(params[:id])
          counts = item_counts_for([list.id])

          render json: {
            data: ListResource.new(list, params: {weight: weight_on(configuration, list), item_count: counts.fetch(list.id, 0)}, with_traits: :full).to_h
          }
        end

        private

        # The list's weight on a configuration: nil when the list does not feed
        # it, and nil when there is no configuration (no primary yet).
        def weight_on(configuration, list)
          return if configuration.nil?

          configuration.ranked_lists.find_by(list: list)&.weight
        end
      end
    end
  end
end
