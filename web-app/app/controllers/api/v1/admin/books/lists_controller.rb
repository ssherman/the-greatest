# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/lists     -- search books lists with audit state and weight
        # GET /api/v1/admin/lists/:id -- one list in full
        # PATCH /api/v1/admin/lists/:id -- any subset of the editable fields (Services::Lists::AdminUpdate)
        #
        # Root-anchor every ::Books:: reference in this namespace.
        class ListsController < BaseController
          include ::Api::V1::Admin::StrictIds
          include ::Api::V1::Admin::FieldUpdate

          require_scopes index: "books:admin:read", show: "books:admin:read", update: "books:admin:write"

          SORTS = %w[weight name id].freeze
          AUDITS = %w[not_audited verified unverifiable in_progress].freeze

          FIELDS = {
            "name" => :string,
            "description" => :string_or_null, "source" => :string_or_null,
            "source_country_origin" => :string_or_null, "url" => :string_or_null,
            "year_published" => :year,
            "number_of_voters" => :count_or_null, "num_years_covered" => :count_or_null,
            "estimated_quality" => :count_or_null,
            "yearly_award" => :boolean, "high_quality_source" => :boolean, "category_specific" => :boolean,
            "location_specific" => :boolean, "creator_specific" => :boolean, "voter_count_estimated" => :boolean,
            "voter_count_unknown" => :boolean, "voter_names_unknown" => :boolean
          }.freeze
          CLEARABLE = %w[description source source_country_origin url year_published number_of_voters
            num_years_covered estimated_quality].freeze

          def index
            status = param_in(:status, ::List.statuses.keys)
            return if performed?
            audit = param_in(:audit, AUDITS)
            return if performed?
            sort = param_in(:sort, SORTS) || "weight"
            return if performed?
            query = params[:q].to_s.strip.presence

            relation = ::Books::List.search_text(query)
            relation = relation.where(status: status) if status
            relation = filter_by_audit(relation, audit) if audit
            relation = sorted(relation, sort)

            echoed = {q: query, status: status, audit: audit, sort: (sort unless sort == "weight")}.compact
            render_page(relation, path: "/api/v1/admin/lists", query: echoed) do |rows|
              lookups = ListResource.lookups(rows)
              rows.map { |list| ListResource.new(list, params: lookups).to_h }
            end
          end

          def show
            list = ::Books::List.find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No books list #{params[:id]}.")) unless list

            render json: {data: ListFullResource.for(list)}
          end

          # PATCH /api/v1/admin/lists/:id -- the list as it now stands, plus `changed`
          def update
            list = ::Books::List.find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No books list #{params[:id]}.")) unless list

            update_fields(record: list, record_key: :list, fields: FIELDS, enums: {}, clearable: CLEARABLE,
              policy: ::Books::ListPolicy, service: ::Services::Lists::AdminUpdate,
              render_with: ->(record) { ListFullResource.for(record) })
          end

          private

          def filter_by_audit(relation, audit)
            case audit
            when "not_audited"
              relation.where.not(id: ::ListAudit.done.select(:list_id))
            when "in_progress"
              relation.where(id: ::ListAudit.open.select(:list_id))
            else
              latest = ::ListAudit.latest_done.where(verdict: audit)
              relation.where(id: latest.select(:list_id))
            end
          end

          def sorted(relation, sort)
            case sort
            when "name" then relation.order(Arel.sql("lists.name ASC"), :id)
            when "id" then relation.order(:id)
            else
              primary = ::Books::RankingConfiguration.default_primary
              return relation.order(Arel.sql("lists.name ASC"), :id) unless primary

              weight = ::RankedList.where(ranking_configuration_id: primary.id).where("ranked_lists.list_id = lists.id").select(:weight)
              relation.order(Arel.sql("(#{weight.to_sql}) DESC NULLS LAST"), :id)
            end
          end

          def param_in(name, allowed)
            value = params[name]
            return nil if value.nil?
            return value.to_s if allowed.include?(value.to_s)

            render_problem(::Api::Problem.new(:invalid_parameter, detail: "#{name} must be one of #{allowed.join(", ")}"))
            nil
          end
        end
      end
    end
  end
end
