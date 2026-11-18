require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class EnrichmentQueuesControllerTest < ActionDispatch::IntegrationTest
          STATUS_KEYS = %w[pending claimed submitted done skipped failed].freeze

          setup do
            host! "dev-new.thegreatestbooks.org"
            @book = ::Books::Book.create!(title: "No Country Yet")
          end

          def json = response.parsed_body

          def queue_row(book = @book) = ::EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")

          def claim(type: "origin", params: {}, token: ApiTokenSecrets::ADMIN)
            post "/api/v1/admin/enrichment_queues/#{type}/claims", params: params, as: :json, headers: bearer(token)
          end

          test "lists both queue types with all six counts and conforms" do
            queue_row
            get "/api/v1/admin/enrichment_queues", headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal %w[origin categories], json["data"].map { |row| row["type"] }
            json["data"].each do |row|
              assert_equal STATUS_KEYS, row["counts"].keys
              assert_equal %w[type kind label version counts], row.keys
            end
            assert_equal 1, json["data"].first["counts"]["pending"]
          end

          test "shows one queue with outcomes and the reference" do
            get "/api/v1/admin/enrichment_queues/origin", headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal "origin", json["data"]["type"]
            assert json["data"]["reference"]["answer_schema"].is_a?(Hash)
            assert_equal STATUS_KEYS, json["data"]["counts"].keys
            assert json["data"]["outcomes"].is_a?(Hash)
          end

          test "an unknown queue is a 404" do
            get "/api/v1/admin/enrichment_queues/nope", headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "claiming needs the write scope" do
            row = queue_row
            claim(token: ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 403, api: :admin)
            assert row.reload.pending?
          end

          test "claiming hands out the item with its payload and a lease" do
            row = queue_row
            claim
            assert_api_response_conform(status: 200, api: :admin)

            item = json["data"].sole
            assert_equal [row.id, "books.origin", "missing", 1], item.values_at("id", "kind", "reason", "attempts")
            assert_equal "No Country Yet", item["payload"]["record"]["title"]
            assert json["meta"]["lease_token"].present?
            assert json["meta"]["lease_expires_at"].present?
            assert_equal 0, json["meta"]["remaining"]
            row.reload
            assert_equal [true, json["meta"]["lease_token"]], [row.claimed?, row.lease_token]
          end

          test "claiming builds each payload once" do
            queue_row
            Services::Books::QueueTypes::Origin.expects(:payload).once.returns({"book_id" => @book.id})
            claim
            assert_response :success
          end

          test "claiming an empty queue returns no items and no lease" do
            claim
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [], json["data"]
            assert_nil json["meta"]["lease_token"]
            assert_equal 0, json["meta"]["remaining"]
          end

          test "claim honours an explicit limit" do
            queue_row
            queue_row(::Books::Book.create!(title: "Second Countryless"))
            claim(params: {limit: 1})
            assert_equal 1, json["data"].size
            assert_equal 1, json["meta"]["remaining"]
          end

          test "claim limit outside 1..25 or not an integer is a 400" do
            row = queue_row
            [26, 0, "5", 2.5, [5]].each do |limit|
              claim(params: {limit: limit})
              assert_api_response_conform(status: 400, api: :admin)
            end
            assert row.reload.pending?
          end

          test "a null limit is the default" do
            queue_row
            claim(params: {limit: nil})
            assert_response :success
            assert_equal 1, json["data"].size
          end

          test "claiming an unknown queue is a 404" do
            claim(type: "nope")
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "claiming without a token is a 401 and with a member token a 403" do
            claim(token: nil)
            assert_api_response_conform(status: 401, api: :admin)
            claim(token: ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)
          end

          test "claiming logs the type, the count and who" do
            queue_row
            Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_enrichment_claim type=origin claimed=1 user_id=\d+ token_id=\d+/)).once
            Rails.logger.stubs(:info).with(Not(regexp_matches(/api_admin_enrichment_claim/)))
            claim
          end
        end
      end
    end
  end
end
