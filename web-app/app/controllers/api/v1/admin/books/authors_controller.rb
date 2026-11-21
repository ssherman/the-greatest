# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET   /api/v1/admin/authors?q=  -- search, provisional authors included
        # GET   /api/v1/admin/authors/:id -- the editable fields
        # PATCH /api/v1/admin/authors/:id -- any subset of them (Services::Books::Authors::AdminUpdate)
        # POST  /api/v1/admin/authors     -- a new author (Services::Books::Authors::AdminCreate)
        # DELETE /api/v1/admin/authors/:id -- an author with no books and no credits (Services::Books::Authors::AdminDelete)
        class AuthorsController < BaseController
          include ::Api::V1::Admin::StrictIds
          include ::Api::V1::Admin::FieldUpdate

          require_scopes index: "books:admin:read", show: "books:admin:read", update: "books:admin:write", create: "books:admin:write",
            destroy: "books:admin:merge"

          FIELDS = {
            "name" => :string, "sort_name" => :string_or_null, "kind" => :enum,
            "birth_year" => :year, "death_year" => :year, "exclude_from_rankings" => :boolean,
            "alternate_names" => :strings
          }.freeze
          CREATE_FIELDS = (FIELDS.keys & %w[name alternate_names birth_year death_year]) + ["wikidata_qid"]
          QID_FORMAT = /\AQ\d+\z/i

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

          # POST /api/v1/admin/authors -- 201 with the new author, as show returns it
          def create
            unless ::Books::AuthorPolicy.new(current_principal.user, ::Books::Author.new).create?
              return render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not create authors."))
            end

            body = json_body
            return bad_body("The body must be a JSON object with name.") if body.nil?

            unknown = body.keys - CREATE_FIELDS
            if unknown.any?
              return render_problem(::Api::Problem.new(:unprocessable,
                detail: "Unknown field#{"s" if unknown.size > 1}: #{unknown.join(", ")}. Fields: #{CREATE_FIELDS.join(", ")}."))
            end
            return bad_body("name is required") unless body.key?("name")

            qid = typed_qid!(body.delete("wikidata_qid")) if body.key?("wikidata_qid")
            # A year may be null (no year), which :year alone would refuse.
            attrs = body.to_h { |key, value| [key, (value.nil? && key.end_with?("_year")) ? nil : typed_value!(key, value, FIELDS.fetch(key))] }

            result = ::Services::Books::Authors::AdminCreate.call(attrs: attrs, wikidata_qid: qid)
            return refuse_create(result) unless result.success?

            author = result.data[:author]
            Rails.logger.info("event=api_admin_author_create token_id=#{current_principal.token.id} token_kind=#{current_principal.token_kind} " \
              "user_id=#{current_principal.user.id} author_id=#{author.id} with_qid=#{!qid.nil?}")
            render status: :created, json: {data: AuthorDetailResource.new(::Books::Author.includes(:cleared_fields).find(author.id)).to_h}
          end

          # DELETE /api/v1/admin/authors/:id -- {data: {id, name, deleted: true}}, plus meta.dry_run on a dry run
          def destroy
            dry_run = strict_dry_run
            return if performed?

            author = ::Books::Author.find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No author #{params[:id]}.")) unless author
            unless ::Books::AuthorPolicy.new(current_principal.user, author).destroy?
              return render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not delete author #{author.id}."))
            end

            result = ::Services::Books::Authors::AdminDelete.call(author: author, dry_run: dry_run)
            return render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.join(", "))) unless result.success?

            unless dry_run
              Rails.logger.info("event=api_admin_author_delete outcome=succeeded token_id=#{current_principal.token.id} " \
                "token_kind=#{current_principal.token_kind} user_id=#{current_principal.user.id} author_id=#{author.id}")
            end
            body = {data: {id: author.id, name: author.name, deleted: true}}
            body[:meta] = {dry_run: true} if dry_run
            render json: body
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

          private

          def strict_dry_run
            return false unless params.key?(:dry_run)

            case params[:dry_run]
            when true, "true" then true
            when false, "false" then false
            else
              render_problem(::Api::Problem.new(:invalid_parameter, detail: "dry_run must be true or false"))
              nil
            end
          end

          def typed_qid!(value)
            unless value.is_a?(String) && value.strip.match?(QID_FORMAT)
              raise ::Api::Page::InvalidParameter, "wikidata_qid must be Q followed by digits, e.g. Q7243"
            end
            value.strip.upcase
          end

          def refuse_create(result)
            if result.code == :conflict
              holder = result.data[:holder]
              return render_problem(::Api::Problem.new(:conflict,
                detail: "Author #{holder.id}, #{holder.name}, already has that Wikidata id. That is probably the same person: link books to author #{holder.id} instead of creating another."))
            end

            render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.join(", ")))
          end
        end
      end
    end
  end
end
