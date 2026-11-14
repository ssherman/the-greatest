# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET   /api/v1/admin/authors?q=  -- search, provisional authors included
        # GET   /api/v1/admin/authors/:id -- the editable fields
        # PATCH /api/v1/admin/authors/:id -- any subset of them (Services::Books::Authors::AdminUpdate)
        class AuthorsController < BaseController
          include ::Api::V1::Admin::StrictIds
          include ::Api::V1::Admin::FieldUpdate

          require_scopes index: "books:admin:read", show: "books:admin:read", update: "books:admin:write"

          FIELDS = {
            "name" => :string, "sort_name" => :string_or_null, "kind" => :enum,
            "birth_year" => :year, "death_year" => :year, "exclude_from_rankings" => :boolean,
            "alternate_names" => :strings
          }.freeze

          # GET /api/v1/admin/authors/:id -- the fields update_author takes
          def show
            author = ::Books::Author.includes(:cleared_fields).find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No author #{params[:id]}.")) unless author

            render json: {data: AuthorDetailResource.new(author).to_h}
          end

          # PATCH /api/v1/admin/authors/:id -- the author as it now stands, plus `changed`
          def update
            author = ::Books::Author.find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No author #{params[:id]}.")) unless author

            update_fields(record: author, record_key: :author, fields: FIELDS, enums: {"kind" => ::Books::Author.kinds.keys},
              clearable: ::ClearedField::CLEARABLE.fetch("Books::Author"), policy: ::Books::AuthorPolicy,
              service: ::Services::Books::Authors::AdminUpdate, resource: AuthorDetailResource)
          end

          def index
            query = required_query or return

            ids = hit_ids(::Search::Books::Search::AuthorGeneral.call(query, size: SEARCH_LIMIT))
            relation = ids.any? ? ::Books::Author.where(id: ids).in_order_of(:id, ids).includes(:primary_ranked_item) : nil

            render_page(relation, path: "/api/v1/admin/authors", query: {q: query}) do |rows|
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
