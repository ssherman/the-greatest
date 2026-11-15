# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/series     -- list; deleted series hidden unless include_deleted=true
        # GET /api/v1/admin/series/:id -- detail with books, any status
        #
        # Root-anchor every ::Books:: reference in this namespace.
        class SeriesController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes index: "books:admin:read", show: "books:admin:read"

          SORTS = %w[title book_count].freeze

          BOOK_COUNT_SQL = "(SELECT COUNT(*) FROM books_series_books WHERE books_series_books.series_id = books_series.id)"

          def index
            sort = param_in(:sort, SORTS) || "title"
            return if performed?
            include_deleted = strict_boolean(:include_deleted)
            return if performed?
            min_books = non_negative_integer(:min_books)
            return if performed?
            max_books = non_negative_integer(:max_books)
            return if performed?
            query = params[:q].to_s.strip.presence

            relation = include_deleted ? ::Books::Series.all : ::Books::Series.active
            if query
              relation = relation.where("books_series.title ILIKE ?", "%#{::Books::Series.sanitize_sql_like(query)}%")
            end
            relation = relation.where("#{BOOK_COUNT_SQL} >= ?", min_books) if min_books
            relation = relation.where("#{BOOK_COUNT_SQL} <= ?", max_books) if max_books
            relation = if sort == "book_count"
              relation.order(Arel.sql("#{BOOK_COUNT_SQL} DESC"), :id)
            else
              relation.order(:title, :id)
            end

            echoed = {q: query, sort: (sort unless sort == "title"), include_deleted: (true if include_deleted),
                      min_books: min_books, max_books: max_books}.compact
            render_page(relation, path: "/api/v1/admin/series", query: echoed) do |rows|
              ids = rows.map(&:id)
              lookups = {
                counts: ::Books::SeriesBook.where(series_id: ids).group(:series_id).count,
                goodreads: ::Identifier.where(identifiable_type: "Books::Series", identifiable_id: ids,
                  identifier_type: :books_series_goodreads_id).pluck(:identifiable_id, :value).to_h
              }
              rows.map { |series| SeriesResource.new(series, params: lookups).to_h }
            end
          end

          def show
            series = ::Books::Series.includes(:representative_book, :identifiers).find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No series #{params[:id]}.")) unless series

            render json: {data: SeriesDetailResource.new(series).to_h}
          end

          private

          def param_in(name, allowed)
            value = params[name]
            return nil if value.nil?
            return value.to_s if allowed.include?(value.to_s)

            render_problem(::Api::Problem.new(:invalid_parameter, detail: "#{name} must be one of #{allowed.join(", ")}"))
            nil
          end

          def strict_boolean(name)
            return false unless params.key?(name)

            case params[name]
            when true, "true" then true
            when false, "false" then false
            else
              render_problem(::Api::Problem.new(:invalid_parameter, detail: "#{name} must be true or false"))
              nil
            end
          end

          def non_negative_integer(name)
            return nil unless params.key?(name)

            value = params[name].to_s
            unless value.match?(/\A\d{1,9}\z/)
              render_problem(::Api::Problem.new(:invalid_parameter, detail: "#{name} must be a non-negative integer"))
              return nil
            end

            value.to_i
          end
        end
      end
    end
  end
end
