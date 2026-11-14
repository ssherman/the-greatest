# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET   /api/v1/admin/books?q=  -- search, provisional books and every kind included
        # GET   /api/v1/admin/books/:id -- the editable fields
        # PATCH /api/v1/admin/books/:id -- any subset of them (Services::Books::AdminUpdate)
        class BooksController < BaseController
          include ::Api::V1::Admin::StrictIds
          include ::Api::V1::Admin::FieldUpdate

          require_scopes index: "books:admin:read", show: "books:admin:read", update: "books:admin:write"

          FIELDS = {
            "title" => :string, "subtitle" => :string_or_null, "sort_title" => :string_or_null,
            "first_published_year" => :year, "book_kind" => :enum, "original_language_id" => :language_id,
            "alternate_titles" => :strings
          }.freeze

          # GET /api/v1/admin/books/:id -- the fields update_book takes
          def show
            book = ::Books::Book.includes(:authors, :original_language, :cleared_fields).find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No book #{params[:id]}.")) unless book

            render json: {data: BookDetailResource.new(book).to_h}
          end

          # PATCH /api/v1/admin/books/:id -- the book as it now stands, plus `changed`
          def update
            book = ::Books::Book.find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No book #{params[:id]}.")) unless book

            update_fields(record: book, record_key: :book, fields: FIELDS, enums: {"book_kind" => ::Books::Book.book_kinds.keys},
              clearable: ::ClearedField::CLEARABLE.fetch("Books::Book"), policy: ::Books::BookPolicy,
              service: ::Services::Books::AdminUpdate, resource: BookDetailResource)
          end

          def index
            query = required_query or return

            ids = hit_ids(::Search::Books::Search::BookGeneral.call(query, size: SEARCH_LIMIT, book_kind: nil, include_provisional: true))
            relation = ids.any? ? ::Books::Book.where(id: ids).in_order_of(:id, ids).includes(:authors, :primary_ranked_item) : nil

            render_page(relation, path: "/api/v1/admin/books", query: {q: query}) do |rows|
              rows.map { |book| BookResource.new(book).to_h }
            end
          end
        end
      end
    end
  end
end
