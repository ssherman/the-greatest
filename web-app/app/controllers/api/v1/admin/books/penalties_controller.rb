# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/penalties -- the books catalogue of penalties (not paged)
        #
        # Root-anchor every ::Books:: reference in this namespace.
        class PenaltiesController < BaseController
          require_scopes index: "books:admin:read"

          def index
            penalties = ::Penalty.where(type: %w[Books::Penalty Global::Penalty], user_id: nil)
              .order(Arel.sql("penalties.category ASC NULLS LAST"), :name, :id).to_a
            ids = penalties.map(&:id)
            primary = ::Books::RankingConfiguration.default_primary
            lookups = {
              values: primary ? ::PenaltyApplication.where(ranking_configuration_id: primary.id, penalty_id: ids).pluck(:penalty_id, :value).to_h : {},
              list_counts: ::ListPenalty.joins(:list).where(penalty_id: ids, lists: {type: "Books::List"}).group(:penalty_id).count
            }
            render json: {data: penalties.map { |penalty| PenaltyResource.new(penalty, params: lookups).to_h }}
          end
        end
      end
    end
  end
end
