# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/discover/books -- the saved-search engine as a read API: filter by
      # category, country, language, length, year, rank range and the caller's read
      # list, in rank order or a seeded random order.
      #
      # Every model and search reference is root-anchored (::Books::…, ::Search::…):
      # inside this module a bare Books:: resolves to Api::V1::Books:: and raises
      # NameError.
      class DiscoverBooksController < BaseController
        include ::Api::SearchBacked

        PATH = "/api/v1/discover/books"
        WINDOW = ::Search::Books::Search::BookAdvanced::MAX_RESULT_WINDOW

        EmptyResult = Struct.new(:books, :total, keyword_init: true)

        def index
          filters = ::Api::DiscoverBookFilters.call(params)
          page_number = ::Api::Page.integer(params[:page], name: "page", default: 1, min: 1, max: ::Api::Page::MAX_PAGE)
          per_page = ::Api::Page.integer(params[:per_page], name: "per_page", default: ::Api::Page::DEFAULT_PER_PAGE, min: 1, max: ::Api::Page::MAX_PER_PAGE)

          max_page = (WINDOW.to_f / per_page).ceil
          if page_number > max_page
            raise ::Api::Page::InvalidParameter,
              "page must be at most #{max_page} at per_page=#{per_page}: only the first #{WINDOW} results can be paged, so narrow the filters"
          end

          result = search(filters, page_number, per_page)
          page = ::Api::Page.new(page: page_number, per_page: per_page, total_count: result.total, max_page: max_page)

          meta = page.meta
          meta = meta.merge(filters: filters.applied) if filters.applied.any?
          meta = meta.merge(order: filters.order.to_s)
          meta = meta.merge(seed: filters.seed) if filters.order == :random
          query = (filters.order == :random) ? filters.applied.merge(order: "random", seed: filters.seed) : filters.applied

          render json: {
            data: result.books.map { |book| BookResource.new(book, params: {rank: book.ranked_position}).to_h },
            meta: meta,
            links: page.links("#{::Api::Host.base_url}#{PATH}", query: query)
          }
        end

        private

        # Like list_books, empty until a primary ranking has been calculated:
        # SavedSearchQuery raises without one.
        def search(filters, page_number, per_page)
          return EmptyResult.new(books: [], total: 0) unless ::Books::RankingConfiguration.default_primary

          ::Books::SavedSearchQuery.call(
            criteria: ::Books::SavedSearchCriteria.new(filters.criteria),
            owner: current_principal.user,
            page: page_number,
            per_page: per_page,
            order: filters.order,
            seed: filters.seed,
            track_total_hits: true
          )
        end
      end
    end
  end
end
