# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/search/books?q= -- full-text search over the catalog, best match first
      #
      # Every model and search reference is root-anchored (::Books::…, ::Search::…):
      # inside this module a bare Books:: resolves to Api::V1::Books:: and raises
      # NameError.
      class BookSearchesController < BaseController
        include ::Api::SearchBacked

        def index
          query = search_text!

          ids = ::Books::BookSearchQuery.hit_ids(query, size: SEARCH_LIMIT)

          # `catalog` and the relation's own count are what keep the page honest:
          # the index can still carry a provisional book, a collection or an id
          # Postgres has lost, and total_count / total_pages come from the rows
          # that exist, so a page is never short of what its meta promises.
          relation = if ids.any?
            ::Books::Book.catalog.where(book_kind: :standalone).where(id: ids).in_order_of(:id, ids)
              .includes(:primary_ranked_item, {book_authors: :author}, {primary_image: {file_attachment: :blob}})
          end

          render_page(relation, path: "/api/v1/search/books", query: {q: query}) do |rows|
            rows.map { |book| BookResource.new(book).to_h }
          end
        end
      end
    end
  end
end
