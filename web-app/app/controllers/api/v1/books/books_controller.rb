# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/books                                  -- the primary ranking, best first, paginated
      # GET /api/v1/ranking_configurations/:id/books       -- the same, on the named configuration
      # GET /api/v1/books/:slug                            -- one book, full shape
      # GET /api/v1/ranking_configurations/:id/books/:slug -- the same, its rank on the named configuration
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class BooksController < BaseController
        def index
          configuration = ranking_configuration
          # Filters are resolved before the page is parsed, so a bad filter beats
          # a bad page (a missing parent configuration still beats both).
          filters = ::Api::RankedBookFilters.call(params)
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
            path: collection_path("books"),
            query: filters.applied,
            meta: filters.applied.any? ? {filters: filters.applied} : {}
          ) do |ranked_item|
            BookResource.new(ranked_item.item, params: {rank: ranked_item.rank}).to_h
          end
        end

        def show
          # Resolved first, so a bad configuration is a 404 before the book is
          # looked at. Bare, the configuration is the primary and the resource
          # reads the primary rank itself, exactly as it always has.
          configuration = ranking_configuration if nested_configuration_id
          # find_by!(slug:), never friendly.find: 137 books have purely numeric
          # slugs and friendly_id resolves slugs before primary keys.
          book = ::Books::Book
            .includes(:categories, :countries, :original_language, :descriptions, {book_authors: :author},
              {primary_image: {file_attachment: :blob}})
            .catalog
            .find_by!(slug: params[:slug])

          resource = if configuration
            # That configuration's rank, or nil when it does not rank the book;
            # never the primary's (params[:rank] present, even when nil).
            rank = ::RankedItem.where(ranking_configuration_id: configuration.id, item: book).pick(:rank)
            BookResource.new(book, params: {rank: rank}, with_traits: :full)
          else
            BookResource.new(book, with_traits: :full)
          end

          render json: {data: resource.to_h}
        end
      end
    end
  end
end
