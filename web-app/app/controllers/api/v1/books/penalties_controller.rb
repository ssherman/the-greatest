# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/penalties -- the books penalty catalogue, read-only and not
      # paged (a few dozen rows). A list's own penalties ride on its show.
      class PenaltiesController < BaseController
        def index
          penalties = ::Penalty.books_catalogue.order(:category, :name)

          render json: {data: penalties.map { |penalty| PenaltyResource.new(penalty).to_h }}
        end
      end
    end
  end
end
