require "test_helper"

module Api
  module V1
    module Admin
      module Books
        # POST /api/v1/admin/list_audits, /:id/finish and /:id/release.
        class ListAuditsControllerTest < ActionDispatch::IntegrationTest
          WRITE = ApiTokenSecrets::ADMIN
          READ = ApiTokenSecrets::ADMIN_READ

          setup do
            host! "dev-new.thegreatestbooks.org"
            @first = ::Books::List.create!(name: "Audit Queue One", status: :active)
            @second = ::Books::List.create!(name: "Audit Queue Two", status: :active)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def send_raw(verb, url, body = nil, token: WRITE)
            send(verb, url, params: body.is_a?(String) ? body : body&.to_json, headers: bearer(token).merge("CONTENT_TYPE" => "application/json"))
          end

          def start(body = {}, token: WRITE) = send_raw(:post, "/api/v1/admin/list_audits", body, token: token)

          def finish(audit_id, body, token: WRITE) = send_raw(:post, "/api/v1/admin/list_audits/#{audit_id}/finish", body, token: token)

          def release(audit_id, body = {}, token: WRITE) = send_raw(:post, "/api/v1/admin/list_audits/#{audit_id}/release", body, token: token)

          def other_admin_token
            user = User.create!(email: "second-admin@example.com", display_name: "Second Admin", role: :admin, email_verified: true,
              original_signup_domain: "thegreatestbooks.org")
            secret = "tg_#{"z" * 40}"
            ApiToken.create!(user: user, name: "second", token_digest: Digest::SHA256.hexdigest(secret), token_prefix: secret[0, 12],
              scopes: ["books:admin:write"], expires_at: 30.days.from_now)
            secret
          end

          def finished_audit_for(list)
            ListAudit.create!(list: list, status: :finished, verdict: :unverifiable, started_at: 1.day.ago, finished_at: Time.current)
          end

          test "start with no list_id takes the next list and reports what remains" do
            start
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal false, json[:data][:resumed]
            assert_equal "in_progress", json[:data][:audit][:status]
            assert_equal json[:data][:audit][:id], ListAudit.find_by!(list_id: json[:data][:list][:id]).id
            assert_kind_of Integer, json[:meta][:remaining]
          end

          test "start with no list_id twice by the same token takes two different lists" do
            start
            first = json[:data]
            start
            assert_api_response_conform(status: 200, api: :admin)

            assert_not_equal first[:audit][:id], json[:data][:audit][:id]
            assert_not_equal first[:list][:id], json[:data][:list][:id]
            assert_equal false, json[:data][:resumed]
          end

          test "a token whose owner fails the list policy is 403 on start, finish and release" do
            start({list_id: @first.id})
            audit_id = json[:data][:audit][:id]
            ::Books::ListPolicy.any_instance.stubs(:update?).returns(false)

            assert_no_difference -> { ListAudit.count } do
              start
              assert_response :forbidden
              start({list_id: @second.id})
              assert_response :forbidden
            end
            finish(audit_id, {verdict: "unverifiable", note: "n", sources: []})
            assert_response :forbidden
            release(audit_id)
            assert_response :forbidden
            assert ListAudit.find(audit_id).in_progress?
          end

          test "an audit by a user with no names reports user #id, never the email" do
            user = users(:regular_user)
            user.update_columns(name: nil, display_name: nil, email: "private-address@example.com")
            audit = ListAudit.create!(list: @first, user: user, started_at: Time.current, lease_expires_at: 1.hour.from_now)
            name = ListAuditResource.new(audit).to_h[:user_name]
            assert_equal "user ##{user.id}", name
          end

          test "start twice on one list by the same token resumes the same audit" do
            start({list_id: @first.id})
            audit_id = json[:data][:audit][:id]
            start({list_id: @first.id})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal audit_id, json[:data][:audit][:id]
            assert_equal true, json[:data][:resumed]
            assert_equal 1, ListAudit.where(list_id: @first.id).count
          end

          test "start on a list another admin is auditing is 409" do
            start({list_id: @first.id})
            assert_response :ok

            start({list_id: @first.id}, token: other_admin_token)
            assert_api_response_conform(status: 409, api: :admin)
          end

          test "start with an empty queue answers null data and zero remaining" do
            ::Books::List.where.not(id: [@first.id, @second.id]).find_each { |list| finished_audit_for(list) unless ListAudit.finished.exists?(list_id: list.id) }
            [@first, @second].each { |list| finished_audit_for(list) }

            start
            assert_api_response_conform(status: 200, api: :admin)

            assert_nil json[:data]
            assert_equal 0, json[:meta][:remaining]
          end

          test "start with a missing or non-books list is 404 and a non-integer list_id is 400" do
            start({list_id: 0})
            assert_response :not_found
            start({list_id: lists(:music_albums_list).id})
            assert_response :not_found
            ["12", 1.5, nil, true].each do |bad|
              start({list_id: bad})
              assert_response :bad_request, bad.inspect
            end
            assert_equal 0, ListAudit.where(list_id: [@first.id, @second.id]).count
          end

          test "start refuses an unknown key with 422" do
            start({list_id: @first.id, extra: 1})
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "start with a read token is 403" do
            start({}, token: READ)
            assert_response :forbidden
          end

          test "finish records the verdict and returns the changes made since the audit began" do
            start({list_id: @first.id})
            audit_id = json[:data][:audit][:id]
            send_raw(:patch, "/api/v1/admin/lists/#{@first.id}", {number_of_voters: 40})
            assert_response :ok

            finish(audit_id, {verdict: "verified", note: "Matches the source.", sources: ["https://example.com/list"]})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal ["finished", "verified"], json[:data].values_at(:status, :verdict)
            assert_includes json[:data][:changes].to_json, "number_of_voters"
          end

          test "finish with verified and no sources is 422 and leaves the audit open" do
            start({list_id: @first.id})
            audit_id = json[:data][:audit][:id]

            finish(audit_id, {verdict: "verified", note: "Looks right.", sources: []})
            assert_api_response_conform(status: 422, api: :admin)
            assert ListAudit.find(audit_id).in_progress?
          end

          test "finish with a bad verdict, a blank note or bad sources is 422" do
            start({list_id: @first.id})
            audit_id = json[:data][:audit][:id]

            [{verdict: "great", note: "x", sources: []}, {verdict: "unverifiable", note: " ", sources: []},
              {verdict: "unverifiable", note: "x", sources: ["not a url"]}].each do |bad|
              finish(audit_id, bad)
              assert_response :unprocessable_entity, bad.inspect
            end
          end

          test "finish with a missing or wrongly typed field is 400 and an unknown key is 422" do
            start({list_id: @first.id})
            audit_id = json[:data][:audit][:id]

            [{note: "x", sources: []}, {verdict: 1, note: "x", sources: []}, {verdict: "unverifiable", sources: []},
              {verdict: "unverifiable", note: "x"}, {verdict: "unverifiable", note: "x", sources: "https://example.com"}].each do |bad|
              finish(audit_id, bad)
              assert_response :bad_request, bad.inspect
            end
            finish(audit_id, {verdict: "unverifiable", note: "x", sources: [], extra: 1})
            assert_response :unprocessable_entity
          end

          test "finish by another admin or on a finished audit is 409" do
            start({list_id: @first.id})
            audit_id = json[:data][:audit][:id]

            finish(audit_id, {verdict: "unverifiable", note: "x", sources: []}, token: other_admin_token)
            assert_api_response_conform(status: 409, api: :admin)
            assert ListAudit.find(audit_id).in_progress?

            finish(audit_id, {verdict: "unverifiable", note: "x", sources: []})
            assert_response :ok
            finish(audit_id, {verdict: "unverifiable", note: "x", sources: []})
            assert_response :conflict
          end

          test "finish and release of a missing audit are 404" do
            finish(0, {verdict: "unverifiable", note: "x", sources: []})
            assert_response :not_found
            release(0)
            assert_response :not_found
          end

          test "release frees the list and the next start hands out the other list before it" do
            ::Books::List.where.not(id: [@first.id, @second.id]).find_each { |list| finished_audit_for(list) unless ListAudit.finished.exists?(list_id: list.id) }
            start({list_id: @first.id})
            audit_id = json[:data][:audit][:id]

            release(audit_id, {note: "ran out of time"})
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal "released", json[:data][:status]

            start
            assert_equal @second.id, json[:data][:list][:id]
            finish(json[:data][:audit][:id], {verdict: "unverifiable", note: "x", sources: []})
            assert_response :ok

            start
            assert_equal @first.id, json[:data][:list][:id]
          end

          test "release by another admin is 409 and keeps the audit open" do
            start({list_id: @first.id})
            audit_id = json[:data][:audit][:id]

            release(audit_id, {}, token: other_admin_token)
            assert_api_response_conform(status: 409, api: :admin)
            assert ListAudit.find(audit_id).in_progress?
          end

          test "release accepts an empty body but refuses an unknown key and a non-string note" do
            start({list_id: @first.id})
            audit_id = json[:data][:audit][:id]

            release(audit_id, {extra: 1})
            assert_response :unprocessable_entity
            release(audit_id, {note: 3})
            assert_response :bad_request
            release(audit_id, "")
            assert_response :ok
          end

          test "finish and release with a read token are 403" do
            start({list_id: @first.id})
            audit_id = json[:data][:audit][:id]

            finish(audit_id, {verdict: "unverifiable", note: "x", sources: []}, token: READ)
            assert_response :forbidden
            release(audit_id, {}, token: READ)
            assert_response :forbidden
          end
        end
      end
    end
  end
end
