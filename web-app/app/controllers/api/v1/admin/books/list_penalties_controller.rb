# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # POST   /api/v1/admin/lists/:id/penalties              -- attach a static penalty ({penalty_id})
        # DELETE /api/v1/admin/lists/:id/penalties/:penalty_id  -- detach it
        #
        # The rules live in Services::Lists::PenaltyLinks. Both are idempotent and answer with the
        # list in the get_admin_list shape plus `changed`. Root-anchor every ::Books:: reference.
        class ListPenaltiesController < BaseController
          include ::Api::V1::Admin::StrictIds
          include ::Api::V1::Admin::FieldUpdate

          require_scope "books:admin:write"

          def create
            list = find_list or return
            return forbidden_update(list) unless allowed?(list)

            body = json_body
            return bad_body("The body must be a JSON object with penalty_id.") if body.nil?

            unknown = body.keys - ["penalty_id"]
            if unknown.any?
              return render_problem(::Api::Problem.new(:unprocessable, detail: "Unknown field#{"s" if unknown.size > 1}: #{unknown.join(", ")}. Only penalty_id is accepted."))
            end

            penalty_id = parse_id(body["penalty_id"])
            return bad_body("penalty_id must be a positive integer") if penalty_id.nil?

            finish(list, "attach", penalty_id, ::Services::Lists::PenaltyLinks.attach(list: list, penalty_id: penalty_id))
          end

          def destroy
            list = find_list or return
            return forbidden_update(list) unless allowed?(list)

            penalty_id = parse_id(params[:penalty_id])
            return bad_body("penalty_id must be a positive integer") if penalty_id.nil?

            finish(list, "detach", penalty_id, ::Services::Lists::PenaltyLinks.detach(list: list, penalty_id: penalty_id))
          end

          private

          def find_list
            list = ::Books::List.find_by(id: parse_id(params[:id]))
            render_problem(::Api::Problem.new(:not_found, detail: "No books list #{params[:id]}.")) unless list
            list
          end

          def allowed?(list) = ::Books::ListPolicy.new(current_principal.user, list).update?

          def finish(list, action, penalty_id, result)
            unless result.success?
              return render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.join(", ")))
            end

            Rails.logger.info("event=api_admin_list_penalty_#{action} changed=#{result.data[:changed]} token_id=#{current_principal.token.id} " \
              "token_kind=#{current_principal.token_kind} user_id=#{current_principal.user.id} list_id=#{list.id} penalty_id=#{penalty_id}")
            render json: {data: ListFullResource.for(list.reload), changed: result.data[:changed]}
          end
        end
      end
    end
  end
end
