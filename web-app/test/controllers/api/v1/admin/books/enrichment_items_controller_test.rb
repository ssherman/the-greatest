require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class EnrichmentItemsControllerTest < ActionDispatch::IntegrationTest
          ANSWER = {"recognized" => true, "original_language" => "Japanese", "nationality" => "Japanese", "confidence" => "high", "reason" => "Stated on Wikipedia"}.freeze
          SOURCES = ["https://example.org/a"].freeze

          setup do
            host! "dev-new.thegreatestbooks.org"
            @book = ::Books::Book.create!(title: "No Country Yet")
            @row = ::EnrichmentRequest.create!(enrichable: @book, kind: "books.origin", reason: "missing")
            post "/api/v1/admin/enrichment_queues/origin/claims", as: :json, headers: bearer(ApiTokenSecrets::ADMIN)
            @token = response.parsed_body["meta"]["lease_token"]
          end

          def json = response.parsed_body

          def submit(body = {}, id: @row.id, token: ApiTokenSecrets::ADMIN)
            body = {lease_token: @token, answer: ANSWER, sources: SOURCES}.merge(body)
            post "/api/v1/admin/enrichment_items/#{id}/submit", params: body, as: :json, headers: bearer(token)
          end

          def skip(body = {}, id: @row.id, token: ApiTokenSecrets::ADMIN)
            body = {lease_token: @token, reason: "Searched three sources, nothing"}.merge(body)
            post "/api/v1/admin/enrichment_items/#{id}/skip", params: body, as: :json, headers: bearer(token)
          end

          test "a valid answer is accepted and applied" do
            submit
            assert_api_response_conform(status: 202, api: :admin)

            assert_equal({"id" => @row.id, "status" => "submitted"}, json["data"])
            assert_equal ["Japanese"], @book.countries.reload.pluck(:name)
            assert @row.reload.done?
          end

          test "an accepted answer is stored and queued, not applied, when the job is held back" do
            Sidekiq::Testing.fake! { submit }
            assert_response :accepted
            @row.reload
            assert_equal ["submitted", ANSWER, SOURCES], [@row.status, @row.answer, @row.sources]
            assert_empty @book.countries.reload
          end

          test "a note is stored" do
            Sidekiq::Testing.fake! { submit({note: "looked at two pages"}) }
            assert_response :accepted
            assert_equal "looked at two pages", @row.reload.note
          end

          test "a wrong lease token is a 409 and nothing is applied" do
            submit({lease_token: "not-the-token"})
            assert_api_response_conform(status: 409, api: :admin)
            assert_empty @book.countries.reload
            assert @row.reload.claimed?
          end

          test "an answer missing a required field is a 422 and the row stays claimed" do
            submit({answer: ANSWER.except("nationality")})
            assert_api_response_conform(status: 422, api: :admin)
            assert_match(/nationality/, json["detail"])
            assert @row.reload.claimed?
          end

          test "empty sources are a 422" do
            submit({sources: []})
            assert_api_response_conform(status: 422, api: :admin)
            assert @row.reload.claimed?
          end

          test "an answer over 50,000 bytes is a 422 and nothing is stored" do
            submit({answer: ANSWER.merge("reason" => "x" * 50_001)})
            assert_api_response_conform(status: 422, api: :admin)
            @row.reload
            assert_equal [true, nil], [@row.claimed?, @row.answer]
          end

          test "an answer that is not an object, or a missing lease token, is a 400" do
            submit({answer: "x"})
            assert_api_response_conform(status: 400, api: :admin)
            submit({lease_token: nil})
            assert_api_response_conform(status: 400, api: :admin)
            post "/api/v1/admin/enrichment_items/#{@row.id}/submit", params: {answer: ANSWER, sources: SOURCES}, as: :json, headers: bearer(ApiTokenSecrets::ADMIN)
            assert_api_response_conform(status: 400, api: :admin)
            assert @row.reload.claimed?
          end

          test "sources that are not an array of strings, or a note that is not a string, are a 400" do
            submit({sources: "https://example.org/a"})
            assert_response :bad_request
            submit({sources: [1]})
            assert_response :bad_request
            submit({note: 5})
            assert_response :bad_request
            submit({lease_token: 5})
            assert_response :bad_request
            assert @row.reload.claimed?
          end

          test "a malformed body is a 400" do
            post "/api/v1/admin/enrichment_items/#{@row.id}/submit", params: "[1]", headers: bearer(ApiTokenSecrets::ADMIN).merge("Content-Type" => "application/json")
            assert_response :bad_request
          end

          test "submitting after the book was destroyed is a 404" do
            @row.delete
            submit
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "an unknown item is a 404" do
            submit({}, id: 999_999_999)
            assert_response :not_found
            skip({}, id: 999_999_999)
            assert_response :not_found
          end

          test "an item of another domain is a 404" do
            @row.update_columns(kind: "movies.something")
            submit
            assert_response :not_found
            skip
            assert_response :not_found
          end

          test "an item whose type is no longer registered is a 404" do
            @row.update_columns(kind: "books.retired")
            submit
            assert_response :not_found
          end

          test "a second submit of the same answer is idempotent" do
            Sidekiq::Testing.fake! do
              submit
              assert_response :accepted
              submit
              assert_response :accepted
            end
          end

          test "skipping closes the item with the reason as its note" do
            skip
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal({"id" => @row.id, "status" => "skipped"}, json["data"])
            @row.reload
            assert_equal ["skipped", "skipped_by_agent", "Searched three sources, nothing"], [@row.status, @row.outcome, @row.note]
          end

          test "a blank skip reason is a 422" do
            skip({reason: "  "})
            assert_api_response_conform(status: 422, api: :admin)
            assert @row.reload.claimed?
          end

          test "a skip reason that is not a string, or a missing token, is a 400" do
            skip({reason: 5})
            assert_api_response_conform(status: 400, api: :admin)
            skip({lease_token: nil})
            assert_response :bad_request
          end

          test "a retried skip is a 409" do
            skip
            skip
            assert_api_response_conform(status: 409, api: :admin)
          end

          test "writes need a write token" do
            [method(:submit), method(:skip)].each do |action|
              action.call({}, token: ApiTokenSecrets::ADMIN_READ)
              assert_api_response_conform(status: 403, api: :admin)
              action.call({}, token: ApiTokenSecrets::MEMBER)
              assert_api_response_conform(status: 403, api: :admin)
              action.call({}, token: nil)
              assert_api_response_conform(status: 401, api: :admin)
            end
            assert @row.reload.claimed?
          end

          test "an account that may not change books gets a 403" do
            ::Books::BookPolicy.any_instance.stubs(:update?).returns(false)
            submit
            assert_api_response_conform(status: 403, api: :admin)
            skip
            assert_response :forbidden
            assert @row.reload.claimed?
          end

          test "submit and skip log the item and who" do
            Sidekiq::Testing.fake! do
              Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_enrichment_submit item_id=#{@row.id} user_id=\d+ token_id=\d+/)).once
              Rails.logger.stubs(:info).with(Not(regexp_matches(/api_admin_enrichment_submit/)))
              submit
            end
          end
        end
      end
    end
  end
end
