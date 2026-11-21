# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # POST /api/v1/admin/list_audits               -- start (or resume) an audit; body {list_id?}
        # POST /api/v1/admin/list_audits/:id/finish    -- record the verdict; body {verdict, note, sources}
        # POST /api/v1/admin/list_audits/:id/release   -- give the list back; body {note?}
        #
        # The rules live in Services::Lists::Audits::{Start,Finish,Release}. A service failure
        # flagged `conflict` is a 409; any other failure is a 422. Root-anchor every ::Books::
        # reference in this namespace.
        class ListAuditsController < BaseController
          include ::Api::V1::Admin::StrictIds
          include ::Api::JsonBody

          require_scope "books:admin:write"

          def start
            body = body_for(%w[list_id]) or return
            list = nil
            if body.key?("list_id")
              list_id = body["list_id"]
              return bad_body("list_id must be an integer") unless list_id.is_a?(Integer)

              list = ::Books::List.find_by(id: list_id)
              return not_found("No books list #{list_id}.") unless list
            end

            return forbidden_update(list || ::Books::List.new) unless allowed?(list || ::Books::List.new)

            result = ::Services::Lists::Audits::Start.call(user: current_principal.user, list: list)
            return failed(result) unless result.success?

            audit = result.data[:audit]
            log("start", audit, resumed: result.data[:resumed])
            data = audit && {
              audit: ListAuditResource.new(audit).to_h,
              resumed: result.data[:resumed],
              list: ListFullResource.for(audit.list.reload)
            }
            render json: {data: data, meta: {remaining: result.data[:remaining]}}
          end

          def finish
            audit = find_audit or return
            return forbidden_update(audit.list) unless allowed?(audit.list)

            body = body_for(%w[verdict note sources], required: true) or return

            unless body["verdict"].is_a?(String) && body["note"].is_a?(String) && body["sources"].is_a?(Array)
              return bad_body("verdict and note must be strings and sources an array of URLs")
            end

            result = ::Services::Lists::Audits::Finish.call(audit: audit, user: current_principal.user,
              verdict: body["verdict"], note: body["note"], sources: body["sources"])
            respond(result, "finish")
          end

          def release
            audit = find_audit or return
            return forbidden_update(audit.list) unless allowed?(audit.list)

            body = body_for(%w[note]) or return
            return bad_body("note must be a string") if body.key?("note") && !body["note"].nil? && !body["note"].is_a?(String)

            result = ::Services::Lists::Audits::Release.call(audit: audit, user: current_principal.user, note: body["note"], admin: false)
            respond(result, "release")
          end

          private

          def allowed?(list) = ::Books::ListPolicy.new(current_principal.user, list).update?

          def forbidden_update(list)
            detail = list.persisted? ? "Your account may not edit list #{list.id}." : "Your account may not edit lists."
            render_problem(::Api::Problem.new(:forbidden, detail: detail))
          end

          # The JSON object, {} for a blank body (every key here is optional unless
          # `required`); nil after rendering the 400 or 422.
          def body_for(allowed, required: false)
            if request.raw_post.to_s.strip.empty? && !required
              return {}
            end

            body = json_body
            if body.nil?
              bad_body("The body must be a JSON object.")
              return
            end

            unknown = body.keys - allowed
            if unknown.any?
              render_problem(::Api::Problem.new(:unprocessable, detail: "Unknown field#{"s" if unknown.size > 1}: #{unknown.join(", ")}. Accepted: #{allowed.join(", ")}."))
              return
            end

            body
          end

          def find_audit
            audit = ::ListAudit.find_by(id: parse_id(params[:id]))
            not_found("No list audit #{params[:id]}.") unless audit
            audit
          end

          def not_found(detail)
            render_problem(::Api::Problem.new(:not_found, detail: detail))
            nil
          end

          def respond(result, action)
            return failed(result) unless result.success?

            audit = result.data[:audit]
            log(action, audit)
            render json: {data: ListAuditResource.new(audit).to_h}
          end

          def failed(result)
            kind = result.data[:conflict] ? :conflict : :unprocessable
            render_problem(::Api::Problem.new(kind, detail: result.errors.join(", ")))
          end

          def log(action, audit, **extra)
            Rails.logger.info("event=api_admin_list_audit_#{action} token_id=#{current_principal.token.id} " \
              "token_kind=#{current_principal.token_kind} user_id=#{current_principal.user.id} " \
              "audit_id=#{audit&.id} list_id=#{audit&.list_id} #{extra.map { |k, v| "#{k}=#{v}" }.join(" ")}".strip)
          end
        end
      end
    end
  end
end
