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
            source_id = parse_id(params.require(:source_id))
            return render_problem(::Api::Problem.new(:invalid_parameter, detail: "source_id must be a positive integer")) if source_id.nil?

            dry_run = ActiveModel::Type::Boolean.new.cast(params[:dry_run]) || false
            target = model_class.find(params[:id])
            source = model_class.find(source_id)

            {"source" => source, "target" => target}.each do |role, record|
              next if policy_class.new(current_principal.user, record).destroy?

              noun = model_class.name.demodulize.downcase
              return render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not delete the #{role} #{noun}"))
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

          # A JSON integer, or a string of plain decimal digits. Never Integer(str):
          # it honours radix prefixes ("010" is 8, "0x1A" is 26, "1_0" is 10), and
          # this id names a record that is about to be deleted.
          def parse_id(value)
            id = value if value.is_a?(Integer)
            id = Integer(value, 10) if value.is_a?(String) && value.match?(/\A\d+\z/)

            (id && id >= 1) ? id : nil
          end

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
