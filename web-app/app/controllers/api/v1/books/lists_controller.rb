# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/lists                              -- the primary ranking's active lists, heaviest first
      # GET /api/v1/ranking_configurations/:id/lists   -- the same, on the named configuration
      # GET /api/v1/lists/:id                          -- any active list, full shape
      #
      # weight is a property of the (list, configuration) pair (spec D1): a
      # collection row carries the weight on the configuration it was read
      # through; show reads the primary and answers null off it (D5).
      #
      # Every model reference is root-anchored. This is the sharp case: inside
      # Api::V1::Books a bare `List` resolves (to ::List, the STI base) while a
      # bare `Books::List` raises NameError -- so it is ::Books::List throughout.
      class ListsController < BaseController
        def index
          configuration = ranking_configuration
          relation = configuration && ::Books::ListsQuery.call(ranking_configuration: configuration)

          render_page(relation, path: collection_path("lists")) do |ranked_lists|
            counts = item_counts_for(ranked_lists.map(&:list_id))
            ranked_lists.map do |ranked_list|
              ListResource.new(ranked_list.list, params: {weight: ranked_list.weight, item_count: counts.fetch(ranked_list.list_id, 0)}).to_h
            end
          end
        end

        def show
          list = ::Books::List.active.find(params[:id])
          counts = item_counts_for([list.id])

          render json: {
            data: ListResource.new(list, params: {weight: primary_weight(list), item_count: counts.fetch(list.id, 0)}, with_traits: :full).to_h
          }
        end

        private

        # The list's weight on the primary configuration: nil off it, and nil
        # when there is no primary yet.
        def primary_weight(list)
          primary = ::Books::RankingConfiguration.default_primary
          return if primary.nil?

          primary.ranked_lists.find_by(list: list)&.weight
        end
      end
    end
  end
end
