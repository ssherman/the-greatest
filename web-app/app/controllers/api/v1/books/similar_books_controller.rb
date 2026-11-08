# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/books/:slug/similar -- the books most like this one
      #
      # A top-N, not a page: the same service as the book page's "similar" card,
      # asked for up to 25. Unlike the card, a search outage is a 503 here
      # (raise_on_failure), so a client can tell "nothing similar" from "search
      # is down".
      #
      # Every model and service reference is root-anchored (::Books::…,
      # ::Services::…): inside this module a bare Books:: resolves to
      # Api::V1::Books:: and raises NameError.
      class SimilarBooksController < BaseController
        include ::Api::SearchBacked

        DEFAULT_LIMIT = 10
        MAX_LIMIT = 25

        def index
          # The book first: a 404 beats a bad limit.
          book = ::Books::Book.catalog.find_by!(slug: params[:slug])
          limit = ::Api::Page.integer(params[:limit], name: "limit", default: DEFAULT_LIMIT, min: 1, max: MAX_LIMIT)

          result = ::Services::Books::SimilarBooks.call(book, limit: limit, raise_on_failure: true)
          books = result.data[:books]

          # One batched query for the ranks the resource reads, instead of one
          # per book -- and without widening what the site's card loads.
          ActiveRecord::Associations::Preloader.new(records: books, associations: :primary_ranked_item).call

          render json: {
            data: books.map { |similar| BookResource.new(similar).to_h },
            meta: {more_available: result.data[:more_available]}
          }
        end
      end
    end
  end
end
