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
          type = param_in(:type, ::Books::BrowseQuery::TYPES) || ::Books::BrowseQuery::TYPES.first
          return if performed?
          sort = param_in(:sort, ::Books::BrowseQuery::SORTS)
          return if performed?

          configuration = ::Books::RankingConfiguration.default_primary
          relation = configuration && ::Books::BrowseQuery
            .categories(ranking_configuration: configuration, type: type, sort: sort)
            .includes(:parent)

          render_ranked_page(relation, path: "/api/v1/categories") do |row|
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

        private

        # An absent param is nil; a value outside `allowed` renders the 400
        # (callers check performed?).
        def param_in(name, allowed)
          value = params[name]
          return nil if value.nil?
          return value.to_s if allowed.include?(value.to_s)

          render_problem(::Api::Problem.new(:invalid_parameter, detail: "#{name} must be one of #{allowed.join(", ")}"))
          nil
        end
      end
    end
  end
end
