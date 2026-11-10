# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/duplicate_candidates     -- the queue; status and item_type filter
        # GET /api/v1/admin/duplicate_candidates/:id -- one pair with detail, any status
        #
        # The same pairs the admin queue page shows, scoped to the books domain.
        # Root-anchor every ::Books:: reference in this namespace.
        class DuplicateCandidatesController < BaseController
          require_scopes index: "books:admin:read", show: "books:admin:read"

          ITEM_TYPES = {"book" => "Books::Book", "author" => "Books::Author"}.freeze
          STATUSES = ::DuplicateCandidate.statuses.keys.freeze

          def index
            status = enum_param!(:status, STATUSES) || "pending"
            item_type = enum_param!(:item_type, ITEM_TYPES.keys)
            pairs = domain_scope.where(status: status).includes(:match_decision, :resolved_by).newest_first
            pairs = pairs.where(item_type: ITEM_TYPES.fetch(item_type)) if item_type

            render_page(pairs, path: "/api/v1/admin/duplicate_candidates",
              query: {status: status, item_type: item_type}.compact) do |rows|
              loaded = ::Services::DuplicateCandidates::PairRecords.call(rows)
              rows.map do |pair|
                DuplicateCandidateResource.new(pair, records: loaded.records, summaries: loaded.summaries).to_h
              end
            end
          end

          def show
            pair = find_pair
            return if performed?

            loaded = ::Services::DuplicateCandidates::PairRecords.call([pair])
            render json: {data: DuplicateCandidateResource.new(pair, records: loaded.records,
              summaries: loaded.summaries, detail: true).to_h}
          end

          private

          def domain_scope
            ::DuplicateCandidate.where(item_type: ITEM_TYPES.values)
          end

          def find_pair
            domain_scope.includes(:match_decision, :resolved_by).find_by(id: params[:id]) || render_problem(
              ::Api::Problem.new(:not_found, detail: "No pending or resolved duplicate pair #{params[:id]}; it may have been folded into another pair by a merge. List the queue again.")
            )
          end
        end
      end
    end
  end
end
