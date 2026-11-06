# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/authors/:slug/books                                  -- an author's books on the primary ranking
      # GET /api/v1/ranking_configurations/:id/authors/:slug/books       -- the same, on the named configuration
      #
      # The author's whole bibliography: ranked books first in rank order, then
      # the unranked ones (rank null) by first publication year and title. The
      # query is the one the author pages use.
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class AuthorBooksController < BaseController
        def index
          # A missing configuration beats an unknown author, which beats a bad page.
          configuration = ranking_configuration
          author = ::Books::Author.catalog.find_by!(slug: params[:slug])

          render_ranked_page(
            ::Books::AuthorBooksQuery.call(author: author, ranking_configuration: configuration),
            path: collection_path("authors/#{author.slug}/books")
          ) do |book|
            BookResource.new(book, params: {rank: book.ranked_position}).to_h
          end
        end
      end
    end
  end
end
