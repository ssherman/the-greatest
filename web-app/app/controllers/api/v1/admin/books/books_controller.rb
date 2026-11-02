# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/books?q= -- search, provisional books and every kind included
        class BooksController < BaseController
          def index
            query = required_query or return

            ids = hit_ids(::Search::Books::Search::BookGeneral.call(query, size: SEARCH_LIMIT, book_kind: nil, include_provisional: true))
            relation = ids.any? ? ::Books::Book.where(id: ids).in_order_of(:id, ids).includes(:authors, :primary_ranked_item) : nil

            render_page(relation, path: "/api/v1/admin/books") do |rows|
              rows.map { |book| BookResource.new(book).to_h }
            end
          end
        end
      end
    end
  end
end
