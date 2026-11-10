# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # The merge endpoints' shared flow. The including controller defines
        # `model_class`, `policy_class`, `resource_for(record)`.
        # The records are permanently deleted, so the order is: parse the body,
        # load both, authorize destroy? on BOTH, snapshot both, then merge
        # (MergeFlow).
        # Root-anchor every ::Books:: reference in this namespace.
        module Mergeable
          extend ActiveSupport::Concern
          include ::Api::V1::Admin::StrictIds
          include MergeFlow

          included do
            require_scope "books:admin:merge"
          end

          def create
            source_id = parse_id(params.require(:source_id))
            return render_problem(::Api::Problem.new(:invalid_parameter, detail: "source_id must be a positive integer")) if source_id.nil?

            dry_run = ActiveModel::Type::Boolean.new.cast(params[:dry_run]) || false
            noun = model_class.name.demodulize.downcase
            target = model_class.find_by(id: params[:id])
            return render_problem(::Api::Problem.new(:not_found, detail: "No target #{noun} #{params[:id]}")) if target.nil?

            source = model_class.find_by(id: source_id)
            return render_problem(::Api::Problem.new(:not_found, detail: "No source #{noun} #{source_id}")) if source.nil?

            body = perform_merge(source:, target:, dry_run:, model_class:, policy_class:, resource_for: method(:resource_for))
            render json: body if body
          end
        end
      end
    end
  end
end
