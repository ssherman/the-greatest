require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class BookMergesControllerTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @target = books_books(:war_and_peace)
            @source = books_books(:crime_and_punishment)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def merge(body, token: ApiTokenSecrets::ADMIN, id: @target.id)
            post "/api/v1/admin/books/#{id}/merge", params: body, as: :json, headers: bearer(token)
          end

          test "an admin token merges: 200, the source is gone and reported as deleted" do
            merge({source_id: @source.id})
            assert_api_response_conform(status: 200, api: :admin)

            assert_not ::Books::Book.exists?(@source.id)
            assert_equal @source.id, json[:data][:deleted][:id]
            assert_equal @target.id, json[:data][:survivor][:id]
            assert_equal false, json[:meta][:dry_run]
            assert_kind_of Array, json[:warnings]
          end

          test "dry_run leaves both records and says so" do
            ::Books::Book::Merger.expects(:new).never

            merge({source_id: @source.id, dry_run: true})
            assert_api_response_conform(status: 200, api: :admin)

            assert ::Books::Book.exists?(@source.id)
            assert ::Books::Book.exists?(@target.id)
            assert_equal true, json[:meta][:dry_run]
            assert_equal @source.id, json[:data][:deleted][:id]
          end

          test "merger warnings are returned" do
            merger = stub(call: ::Books::Book::Merger::Result.new(success?: true, data: @target, errors: []),
              stats: {post_commit_error: "Redis down"})
            ::Books::Book::Merger.expects(:new).returns(merger)

            merge({source_id: @source.id})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal ["post_commit_error"], json[:warnings].map { |w| w[:code] }
          end

          test "a read-only admin token is refused with insufficient_scope" do
            merge({source_id: @source.id}, token: ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "insufficient_scope", json[:code]
            assert ::Books::Book.exists?(@source.id)
          end

          test "a member token is refused" do
            merge({source_id: @source.id}, token: ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)

            assert ::Books::Book.exists?(@source.id)
          end

          test "no token is a 401" do
            post "/api/v1/admin/books/#{@target.id}/merge", params: {source_id: @source.id}, as: :json
            assert_api_response_conform(status: 401, api: :admin)
          end

          test "merging a book into itself is a 422 and deletes nothing" do
            merge({source_id: @target.id})
            assert_api_response_conform(status: 422, api: :admin)

            assert_equal "unprocessable", json[:code]
            assert ::Books::Book.exists?(@target.id)
          end

          test "a missing source is a 404" do
            merge({source_id: 0})
            assert_api_response_conform(status: 404, api: :admin)

            assert ::Books::Book.exists?(@target.id)
          end

          test "a missing target is a 404" do
            merge({source_id: @source.id}, id: 0)
            assert_api_response_conform(status: 404, api: :admin)

            assert ::Books::Book.exists?(@source.id)
          end

          test "a non-integer source_id is a 400" do
            merge({source_id: "abc"})
            assert_api_response_conform(status: 400, api: :admin)

            assert_equal "invalid_parameter", json[:code]
            assert ::Books::Book.exists?(@source.id)
          end

          test "no body is a 400" do
            post "/api/v1/admin/books/#{@target.id}/merge", headers: bearer(ApiTokenSecrets::ADMIN)
            # A missing body fails the document's request schema, so only status and code are checked.
            assert_response :bad_request
            assert_equal "invalid_parameter", json[:code]

            assert ::Books::Book.exists?(@source.id)
          end

          # The token's merge scope is itself decided by a destroy? check on the
          # class, so only the one record is refused; everything else is allowed.
          def refuse_delete_of(refused)
            ::Books::BookPolicy.stubs(:new).with { |_user, record| record != refused }
              .returns(stub_everything(index?: true, destroy?: true))
            ::Books::BookPolicy.stubs(:new).with { |_user, record| record == refused }
              .returns(stub_everything(destroy?: false))
          end

          def victim(id) = ::Books::Book.find_by(id: id) || ::Books::Book.create!(title: "Victim", id: id)

          test "a zero-padded decimal source_id is read as decimal, never octal" do
            octal_victim = victim(8)
            merge({source_id: "010"})

            assert_response :not_found
            assert ::Books::Book.exists?(octal_victim.id)
            assert ::Books::Book.exists?(@source.id)
          end

          test "radix and underscore forms of source_id are a 400 and delete nothing" do
            victims = [26, 10, 8].map { |id| victim(id) }
            ["0x1A", "1_0", "0b1010", "010x", 5.5, true].each do |bad|
              merge({source_id: bad})
              assert_response :bad_request, bad.inspect
              assert_equal "invalid_parameter", json[:code]
            end
            victims.each { |v| assert ::Books::Book.exists?(v.id) }
            assert ::Books::Book.exists?(@source.id)
          end

          test "a failing merger is a 422 with its errors and deletes nothing" do
            merger = stub(call: ::Books::Book::Merger::Result.new(success?: false, data: nil, errors: ["boom"]), stats: {})
            ::Books::Book::Merger.expects(:new).returns(merger)

            merge({source_id: @source.id})
            assert_api_response_conform(status: 422, api: :admin)

            assert_equal "unprocessable", json[:code]
            assert_includes json[:detail], "boom"
            assert ::Books::Book.exists?(@source.id)
          end

          test "a policy refusal on the source is a 403 forbidden and deletes nothing" do
            refuse_delete_of(@source)

            merge({source_id: @source.id})
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "forbidden", json[:code]
            assert_includes json[:detail], "the source book"
            assert ::Books::Book.exists?(@source.id)
            assert ::Books::Book.exists?(@target.id)
          end

          test "a policy refusal on the target is a 403 forbidden and deletes nothing" do
            refuse_delete_of(@target)

            merge({source_id: @source.id})
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "forbidden", json[:code]
            assert_includes json[:detail], "the target book"
            assert ::Books::Book.exists?(@source.id)
          end

          test "a real merge writes exactly one merge log line" do
            Rails.logger.stubs(:info)
            Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_merge .*record_type=Books::Book .*source_id=#{@source.id} target_id=#{@target.id}/)).once

            merge({source_id: @source.id})
            assert_response :ok
          end

          test "a dry run writes no merge log line" do
            Rails.logger.stubs(:info)
            Rails.logger.expects(:info).with(regexp_matches(/api_admin_merge/)).never

            merge({source_id: @source.id, dry_run: true})
            assert_response :ok
          end

          test "the route does not exist on the music host" do
            host! "dev.thegreatestmusic.org"

            merge({source_id: @source.id})

            assert_response :not_found
          end
        end
      end
    end
  end
end
