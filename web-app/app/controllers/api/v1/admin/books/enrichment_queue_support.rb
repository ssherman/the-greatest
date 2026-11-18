# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # What the two enrichment controllers share: the plain JSON body, the
        # policy check and the audit log line. The queue logic itself lives in
        # Services::EnrichmentQueue; the controllers only parse and map Results.
        module EnrichmentQueueSupport
          DOMAIN = "books"
          VIA = "api"

          private

          def acting_user = current_principal.user

          def may_change_books?
            return true if ::Books::BookPolicy.new(acting_user, ::Books::Book.new).update?

            render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not change books"))
            false
          end

          # The JSON object as sent, with String keys all the way down. Not
          # params: ActionController::Parameters is not a Hash, and the answer
          # must reach the service as one. nil when the body is not an object.
          def json_body
            parsed = JSON.parse(request.raw_post.to_s)
            parsed.is_a?(Hash) ? parsed : nil
          rescue JSON::ParserError
            nil
          end

          def invalid!(detail) = raise(::Api::Page::InvalidParameter, detail)

          def log_enrichment(action, subject)
            Rails.logger.info("event=api_admin_enrichment_#{action} #{subject} user_id=#{acting_user.id} " \
              "token_id=#{current_principal.token.id}")
          end
        end
      end
    end
  end
end
