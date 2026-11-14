# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/repair_verdicts      -- the Goodreads repair-verdict review queue; kind, status, decided_by,
        #                                           confidence and guess filters
        # GET /api/v1/admin/repair_verdicts/:id  -- one verdict with its payload, books, candidates and source rows
        #
        # The same verdicts the admin page shows. Superseded verdicts never appear in the list. Root-anchor every
        # ::Books:: reference in this namespace.
        class RepairVerdictsController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes index: "books:admin:read", show: "books:admin:read"

          Filter = ::Services::Books::RepairVerdicts::Filter

          def index
            filters = {
              kind: enum_param!(:kind, Filter::KINDS),
              status: enum_param!(:status, Filter::STATUSES) || "proposed",
              decided_by: enum_param!(:decided_by, Filter::DECIDED_BY),
              confidence: enum_param!(:confidence, Filter::CONFIDENCES),
              guess: enum_param!(:guess, %w[true])
            }
            verdicts = Filter.call(kind: filters[:kind], decided_by: filters[:decided_by],
              confidence: filters[:confidence], guess: filters[:guess])
              .where(status: filters[:status]).newest_first

            render_page(verdicts, path: "/api/v1/admin/repair_verdicts", query: filters.compact) do |rows|
              rows.map { |verdict| RepairVerdictResource.new(verdict).to_h }
            end
          end

          def show
            verdict = ::Books::RepairVerdict.find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No repair verdict #{params[:id]}.")) unless verdict

            render json: {data: RepairVerdictDetailResource.new(verdict).to_h}
          end
        end
      end
    end
  end
end
