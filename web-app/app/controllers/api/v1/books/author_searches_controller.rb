# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/search/authors?q= -- search over author names and alternate
      # names, best match first
      #
      # Every model and search reference is root-anchored (::Books::…, ::Search::…):
      # inside this module a bare Books:: resolves to Api::V1::Books:: and raises
      # NameError.
      class AuthorSearchesController < BaseController
        include ::Api::SearchBacked

        def index
          query = search_text!

          hits = ::Search::Books::Search::AuthorGeneral.call(query, size: SEARCH_LIMIT)
          ids = hits.map { |hit| hit[:id].to_i }.uniq

          # `catalog` and the relation's own count keep the page honest: the index
          # can still carry a provisional author or an id Postgres has lost, and
          # total_count / total_pages come from the rows that exist.
          relation = if ids.any?
            ::Books::Author.catalog.where(id: ids).in_order_of(:id, ids)
              .includes(:primary_ranked_item, {primary_image: {file_attachment: :blob}})
          end

          render_ranked_page(relation, path: "/api/v1/search/authors", query: {q: query}) do |author|
            AuthorResource.new(author).to_h
          end
        end
      end
    end
  end
end
