# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/categories/:slug/books                                       -- the primary ranking filtered to
      #                                                                              one category, best first
      # GET /api/v1/ranking_configurations/:id/categories/:slug/books                -- the same, on the named configuration
      #
      # Same rows, envelope and filter parameters as /api/v1/books; the path
      # category is one more category filter, so category_id intersects with it.
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class CategoryBooksController < BaseController
        def index
          # A missing configuration beats an unknown category, which beats a bad
          # filter, which beats a bad page.
          configuration = ranking_configuration
          category = public_category!(params[:slug])
          filters = ::Api::RankedBookFilters.call(params, path_category: category)
          relation = configuration && ::Books::RankedBooksQuery.call(
            ranking_configuration: configuration,
            categories: filters.categories,
            countries: filters.countries,
            year_start: filters.year_start,
            year_end: filters.year_end,
            collection: filters.collection
          )

          render_ranked_page(
            relation,
            path: collection_path("categories/#{category.slug}/books"),
            query: filters.applied,
            meta: filters.applied.any? ? {filters: filters.applied} : {}
          ) do |ranked_item|
            BookResource.new(ranked_item.item, params: {rank: ranked_item.rank}).to_h
          end
        end
      end
    end
  end
end
