# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # The merge endpoints' shared flow. The including controller defines
        # `model_class`, `policy_class`, `resource_for(record)`.
        # The records are permanently deleted, so the order is: parse the body,
        # load both, authorize destroy? on BOTH, snapshot both, then merge.
        # Root-anchor every ::Books:: reference in this namespace.
        module Mergeable
          extend ActiveSupport::Concern

          included do
            require_scope "books:admin:merge"
          end

          def create
            source_id = Integer(params.require(:source_id).to_s, exception: false)
            return render_problem(::Api::Problem.new(:invalid_parameter, detail: "source_id must be an integer")) if source_id.nil?

            dry_run = ActiveModel::Type::Boolean.new.cast(params[:dry_run]) || false
            target = model_class.find(params[:id])
            source = model_class.find(source_id)

            unless [source, target].all? { |record| policy_class.new(current_principal.user, record).destroy? }
              return render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not delete this record"))
            end

            # Captured before the merge: the source row does not exist afterwards.
            deleted = resource_for(source)
            result = ::Services::Books::AdminMerge.call(source:, target:, dry_run:)
            unless result.success?
              return render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.join(", ")))
            end

            log_merge(source:, target:) unless dry_run
            render json: {
              data: {survivor: resource_for(target), deleted: deleted},
              meta: {dry_run: dry_run},
              warnings: result.data[:warnings]
            }
          end

          private

          def log_merge(source:, target:)
            Rails.logger.info(
              "event=api_admin_merge token_id=#{current_principal.token.id} user_id=#{current_principal.user.id} " \
              "record_type=#{model_class.name} source_id=#{source.id} target_id=#{target.id}"
            )
          end
        end
      end
    end
  end
end
