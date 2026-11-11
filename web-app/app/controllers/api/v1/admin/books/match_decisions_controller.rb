# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/match_decisions      -- the review queue; entity, outcome, confidence,
        #                                           decided_by, reviewed and verify filters
        # GET /api/v1/admin/match_decisions/:id  -- one decision with its query snapshot and candidates
        #
        # The same decisions the admin audit page shows, scoped to the books
        # finders in DataImporters::FinderRegistry. Root-anchor every ::Books::
        # reference in this namespace.
        class MatchDecisionsController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes index: "books:admin:read", show: "books:admin:read"

          Filter = ::Services::MatchDecisions::Filter

          def index
            filters = {
              entity: enum_param!(:entity, entities.keys),
              outcome: enum_param!(:outcome, Filter::OUTCOMES),
              confidence: enum_param!(:confidence, Filter::CONFIDENCES),
              decided_by: enum_param!(:decided_by, Filter::DECIDED_BY),
              reviewed: enum_param!(:reviewed, Filter::REVIEWED) || "pending",
              verify: enum_param!(:verify, Filter::VERIFY) || "hide"
            }
            decisions = Filter.call(domain_scope, filters).includes(:record, :subject, :reviewed_by)
              .newest_first.order(id: :desc)

            render_page(decisions, path: "/api/v1/admin/match_decisions", query: filters.compact) do |rows|
              rows.map { |decision| MatchDecisionResource.new(decision).to_h }
            end
          end

          def show
            decision = find_decision
            return if performed?

            summaries = MatchDecisionResource.summaries_for([decision])
            render json: {data: MatchDecisionResource.new(decision, summaries: summaries, detail: true).to_h}
          end

          private

          # label.parameterize => finder, for this domain's registered finders.
          def entities
            ::DataImporters::FinderRegistry.for_domain(:books).to_h { |entry| [entry.label.parameterize, entry.finder] }
          end

          def domain_scope
            ::MatchDecision.where(finder: ::DataImporters::FinderRegistry.for_domain(:books).map(&:finder))
          end

          def find_decision
            id = parse_id(params[:id])
            domain_scope.includes(:record, :subject, :reviewed_by).find_by(id: id) || render_problem(
              ::Api::Problem.new(:not_found, detail: "No match decision #{params[:id]} in the books queue.")
            )
          end
        end
      end
    end
  end
end
