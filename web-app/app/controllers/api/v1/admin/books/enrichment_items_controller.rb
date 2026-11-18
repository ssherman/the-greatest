# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # POST /api/v1/admin/enrichment_items/:id/submit -- {lease_token, answer, sources, note}: answer a claimed item
        # POST /api/v1/admin/enrichment_items/:id/skip   -- {lease_token, reason}: close a claimed item without an answer
        #
        # Submit answers 202: the answer is applied by a background job, so the response says what was accepted, not
        # what was applied. A row of another domain, or of a type no longer registered, is a 404.
        # Root-anchor every ::Books:: reference in this namespace.
        class EnrichmentItemsController < BaseController
          include ::Api::V1::Admin::StrictIds
          include EnrichmentQueueSupport

          require_scopes submit: "books:admin:write", skip: "books:admin:write"

          Registry = ::Services::EnrichmentQueue::Registry
          Submit = ::Services::EnrichmentQueue::Submit
          Skip = ::Services::EnrichmentQueue::Skip

          def submit
            row = find_row
            return if performed?
            return unless may_change_books?

            body = required_body
            lease_token = string_field!(body, "lease_token", required: true)
            answer = body["answer"]
            invalid!("answer must be a JSON object") unless answer.is_a?(Hash)
            sources = body["sources"]
            invalid!("sources must be an array of strings") unless sources.is_a?(Array) && sources.all?(String)
            note = string_field!(body, "note", required: false)

            result = Submit.call(request: row, lease_token: lease_token, answer: answer, sources: sources, note: note,
              user: acting_user, via: VIA)
            return render_failure(result) unless result.success?

            log_enrichment("submit", "item_id=#{row.id}")
            render json: {data: {id: row.id, status: "submitted"}}, status: :accepted
          end

          def skip
            row = find_row
            return if performed?
            return unless may_change_books?

            body = required_body
            lease_token = string_field!(body, "lease_token", required: true)
            reason = string_field!(body, "reason", required: true)

            result = Skip.call(request: row, lease_token: lease_token, reason: reason, user: acting_user, via: VIA)
            return render_failure(result) unless result.success?

            log_enrichment("skip", "item_id=#{row.id}")
            render json: {data: status_of(result.data[:request])}
          end

          private

          def find_row
            row = ::EnrichmentRequest.find_by(id: parse_id(params[:id]))
            registered = row && Registry.for_domain(DOMAIN).any? { |type| type.kind == row.kind }
            return row if registered

            render_problem(::Api::Problem.new(:not_found, detail: "No enrichment item #{params[:id]}."))
          end

          def required_body
            json_body || invalid!("The body must be a JSON object.")
          end

          def string_field!(body, key, required:)
            value = body[key]
            return nil if value.nil? && !required
            invalid!("#{key} must be a string") unless value.is_a?(String)

            value
          end

          def status_of(row) = {id: row.id, status: row.status}

          def render_failure(result)
            error = result.errors.first
            code = (error[:code] == :conflict) ? :conflict : :unprocessable
            render_problem(::Api::Problem.new(code, detail: error[:detail]))
          end
        end
      end
    end
  end
end
