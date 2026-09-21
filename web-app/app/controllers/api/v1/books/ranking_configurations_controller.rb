# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/ranking_configurations      -- global book rankings, primary first
      # GET /api/v1/ranking_configurations/:id  -- one of them
      #
      # Only global, unarchived Books::RankingConfiguration rows are addressable
      # (spec D3): a member's own configuration, shared or not, an archived one,
      # or the authors configuration is a 404 -- STI keeps the last of those out
      # of the scope without a type predicate.
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class RankingConfigurationsController < BaseController
        def index
          relation = ::Books::RankingConfiguration.global.active.order(primary: :desc, created_at: :desc, id: :desc)

          render_page(relation, path: "/api/v1/ranking_configurations") do |configurations|
            counts = counts_for(configurations.map(&:id))
            configurations.map do |configuration|
              RankingConfigurationResource.new(configuration, params: counts.fetch(configuration.id)).to_h
            end
          end
        end

        def show
          configuration = ::Books::RankingConfiguration.global.active.find(params[:id])
          counts = counts_for([configuration.id])

          render json: {data: RankingConfigurationResource.new(configuration, params: counts.fetch(configuration.id)).to_h}
        end

        private

        # {id => {item_count:, list_count:}} in two grouped queries whatever the
        # page size, and none at all for an empty page. list_count filters on
        # ::Books::ListsQuery's own predicate, so it equals the lists
        # sub-collection's total_count.
        def counts_for(ids)
          return {} if ids.empty?

          items = ::RankedItem.where(ranking_configuration_id: ids, item_type: "Books::Book").where.not(rank: nil)
            .group(:ranking_configuration_id).count
          lists = ::RankedList.where(ranking_configuration_id: ids).joins(:list)
            .where(::Books::ListsQuery.active_list_conditions)
            .group(:ranking_configuration_id).count

          ids.index_with { |id| {item_count: items.fetch(id, 0), list_count: lists.fetch(id, 0)} }
        end
      end
    end
  end
end
