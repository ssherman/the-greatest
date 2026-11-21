# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/lists     -- search books lists with audit state and weight
        # GET /api/v1/admin/lists/:id -- one list in full
        #
        # Root-anchor every ::Books:: reference in this namespace.
        class ListsController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes index: "books:admin:read", show: "books:admin:read"

          SORTS = %w[weight name id].freeze
          AUDITS = %w[not_audited verified unverifiable in_progress].freeze

          LATEST_DONE_AUDIT_SQL = <<~SQL.squish
            list_audits.id = (SELECT latest.id FROM list_audits latest
              WHERE latest.list_id = list_audits.list_id AND latest.status = :finished
              ORDER BY latest.finished_at DESC, latest.id DESC LIMIT 1)
          SQL

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

          private

          def filter_by_audit(relation, audit)
            case audit
            when "not_audited"
              relation.where.not(id: ::ListAudit.done.select(:list_id))
            when "in_progress"
              relation.where(id: ::ListAudit.open.select(:list_id))
            else
              latest = ::ListAudit.where(verdict: audit).where(LATEST_DONE_AUDIT_SQL, finished: ::ListAudit.statuses[:finished])
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
