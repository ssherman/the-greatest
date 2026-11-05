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
        # The most hits a query pages through. Search is a lookup, not an export:
        # a query that matches more than this should be refined.
        SEARCH_LIMIT = 100

        # OpenSearch being down is not our bug, so it is a documented 503 and not
        # the generic 500 an unexpected exception gets.
        rescue_from(*::Search::Shared::Client::UNAVAILABLE_ERRORS) do |error|
          Rails.logger.warn("API book search unavailable: #{error.class}")
          render_problem(::Api::Problem.new(:search_unavailable, detail: "Search is temporarily unavailable. Retry shortly."))
        end

        # A query this long is a pasted paragraph, not a search. Left uncapped it
        # exceeds OpenSearch's max_clause_count, and the 400 that comes back is a
        # failure of ours that the client could do nothing about.
        MAX_QUERY_LENGTH = 200

        def index
          raw = params[:q]
          # `q[]=war` arrives as an Array and `q[a]=war` as Parameters: neither is
          # a search string, and to_s would turn it into one.
          raise ::Api::Page::InvalidParameter, "q must be a single value" unless raw.nil? || raw.is_a?(String)

          query = raw.to_s.strip
          return render_problem(::Api::Problem.new(:invalid_parameter, detail: "q is required")) if query.blank?
          raise ::Api::Page::InvalidParameter, "q must be at most #{MAX_QUERY_LENGTH} characters" if query.length > MAX_QUERY_LENGTH

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
