# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/categories        -- categories of one type with ranked books, paginated
      # GET /api/v1/categories/:slug  -- one category; old and merged slugs resolve
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class CategoriesController < BaseController
        def index
          type = enum_param!(:type, ::Books::BrowseQuery::TYPES) || ::Books::BrowseQuery::TYPES.first
          sort = enum_param!(:sort, ::Books::BrowseQuery::SORTS)

          configuration = ::Books::RankingConfiguration.default_primary
          relation = configuration && ::Books::BrowseQuery
            .categories(ranking_configuration: configuration, type: type, sort: sort)
            .includes(parent: :merged_into)

          # The filters ride along on the paging links, or `next` would fall back
          # to the default type and sort and silently switch lists.
          filters = {type: params[:type].presence && type, sort: sort}.compact
          render_ranked_page(relation, path: "/api/v1/categories", query: filters) do |row|
            CategoryResource.new(row, params: {book_count: row.ranked_count}).to_h
          end
        end

        def show
          category = public_category!(params[:slug])
          configuration = ::Books::RankingConfiguration.default_primary
          count = if configuration
            ::Books::RankedBooksQuery
              .call(ranking_configuration: configuration, categories: [category])
              .except(:includes, :order)
              .count
          else
            0
          end

          render json: {data: CategoryResource.new(category, params: {book_count: count}).to_h}
        end
      end
    end
  end
end
