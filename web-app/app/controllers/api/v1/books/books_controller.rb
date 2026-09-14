# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/books        -- the primary ranking, best first, paginated
      # GET /api/v1/books/:slug  -- one book, full shape
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class BooksController < BaseController
        def index
          ranking_configuration = ::Books::RankingConfiguration.default_primary
          relation = ranking_configuration && ::Books::RankedBooksQuery.call(ranking_configuration: ranking_configuration)

          render_ranked_page(relation, path: "/api/v1/books") do |ranked_item|
            BookResource.new(ranked_item.item, params: {rank: ranked_item.rank}).to_h
          end
        end

        def show
          # find_by!(slug:), never friendly.find: 137 books have purely numeric
          # slugs and friendly_id resolves slugs before primary keys.
          book = ::Books::Book
            .includes(:categories, :countries, :original_language, :descriptions, {book_authors: :author},
              {primary_image: {file_attachment: :blob}})
            .find_by!(slug: params[:slug])

          render json: {data: BookResource.new(book, with_traits: :full).to_h}
        end
      end
    end
  end
end
