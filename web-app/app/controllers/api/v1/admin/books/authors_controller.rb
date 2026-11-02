# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/authors?q= -- search, provisional authors included
        class AuthorsController < BaseController
          def index
            query = required_query or return

            ids = hit_ids(::Search::Books::Search::AuthorGeneral.call(query, size: SEARCH_LIMIT))
            relation = ids.any? ? ::Books::Author.where(id: ids).in_order_of(:id, ids).includes(:primary_ranked_item) : nil

            render_page(relation, path: "/api/v1/admin/authors") do |rows|
              # One grouped count for the page, not one per author.
              counts = ::Books::BookAuthor.where(author_id: rows.map(&:id)).group(:author_id).count
              rows.map { |author| AuthorResource.new(author, params: {book_counts: counts}).to_h }
            end
          end
        end
      end
    end
  end
end
