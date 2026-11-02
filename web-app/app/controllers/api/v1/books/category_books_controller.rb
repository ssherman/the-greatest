# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/categories/:slug/books -- the primary ranking filtered to
      # one category, best first. Same rows and envelope as /api/v1/books.
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class CategoryBooksController < BaseController
        def index
          category = public_category!(params[:slug])
          configuration = ::Books::RankingConfiguration.default_primary
          relation = configuration && ::Books::RankedBooksQuery.call(ranking_configuration: configuration, categories: [category])

          render_ranked_page(relation, path: "/api/v1/categories/#{category.slug}/books") do |ranked_item|
            BookResource.new(ranked_item.item, params: {rank: ranked_item.rank}).to_h
          end
        end
      end
    end
  end
end
