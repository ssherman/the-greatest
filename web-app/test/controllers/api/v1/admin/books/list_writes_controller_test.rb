require "test_helper"

module Api
  module V1
    module Admin
      module Books
        # PATCH /api/v1/admin/lists/:id and the list penalty attach/detach routes.
        class ListWritesControllerTest < ActionDispatch::IntegrationTest
          WRITE = ApiTokenSecrets::ADMIN
          READ = ApiTokenSecrets::ADMIN_READ

          setup do
            host! "dev-new.thegreatestbooks.org"
            @list = lists(:books_list)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def send_raw(verb, url, body = nil, token: WRITE)
            send(verb, url, params: body.is_a?(String) ? body : body&.to_json, headers: bearer(token).merge("CONTENT_TYPE" => "application/json"))
          end

          def patch_list(body, token: WRITE) = send_raw(:patch, "/api/v1/admin/lists/#{@list.id}", body, token: token)

          def penalties_path(penalty_id = nil) = ["/api/v1/admin/lists/#{@list.id}/penalties", penalty_id].compact.join("/")

          test "update changes the fields, clears with null and lists what changed" do
            patch_list({number_of_voters: 12, voter_count_estimated: true, description: nil})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal %w[description number_of_voters voter_count_estimated], json[:changed].sort
            assert_equal @list.id, json[:data][:id]
            assert_equal [12, true, nil], json[:data].values_at(:number_of_voters, :voter_count_estimated, :description)
            @list.reload
            assert_equal [12, true, nil], [@list.number_of_voters, @list.voter_count_estimated, @list.description]
          end

          test "update with a read token is 403 and writes nothing" do
            assert_no_changes -> { @list.reload.attributes } do
              patch_list({number_of_voters: 12}, token: READ)
              assert_api_response_conform(status: 403, api: :admin)
            end
          end

          test "update with an estimated_quality beyond the integer column is 422 and writes nothing" do
            assert_no_changes -> { @list.reload.attributes } do
              patch_list({number_of_voters: 12, estimated_quality: 3_000_000_000})
              assert_response :unprocessable_entity
            end
          end

          test "update refuses the wrong JSON type with 400 and writes nothing" do
            [{number_of_voters: "12"}, {number_of_voters: -1}, {number_of_voters: 1.5}, {high_quality_source: nil},
              {yearly_award: "true"}, {name: 3}, {url: 3}, {year_published: "1990"}, {estimated_quality: true}].each do |bad|
              assert_no_changes -> { @list.reload.attributes } do
                patch_list(bad)
                assert_response :bad_request, bad.inspect
              end
            end
          end

          test "update with an empty or non-object body is 400" do
            patch_list({})
            assert_api_response_conform(status: 400, api: :admin)
            patch_list("[1]")
            assert_response :bad_request
          end

          test "update refuses a value the model rejects with 422 and writes nothing" do
            assert_no_changes -> { @list.reload.attributes } do
              patch_list({num_years_covered: 0, name: "Renamed"})
              assert_api_response_conform(status: 422, api: :admin)
            end
          end

          test "update refuses status and other uneditable keys with 422 naming the editable fields" do
            assert_no_changes -> { @list.reload.attributes } do
              patch_list({status: "approved"})
              assert_api_response_conform(status: 422, api: :admin)
              assert_includes json[:detail], "number_of_voters"

              patch_list({raw_content: "x"})
              assert_response :unprocessable_entity
            end
          end

          test "update of an unknown or non-books list is 404" do
            send_raw(:patch, "/api/v1/admin/lists/0", {name: "x"})
            assert_response :not_found
            send_raw(:patch, "/api/v1/admin/lists/#{lists(:music_albums_list).id}", {name: "x"})
            assert_response :not_found
          end

          test "attach links a penalty and answers with the list and changed" do
            penalty = penalties(:books_one_year_penalty)

            send_raw(:post, penalties_path, {penalty_id: penalty.id})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal true, json[:changed]
            assert_includes json[:data][:penalties].map { |p| p[:id] }, penalty.id
            assert ListPenalty.exists?(list: @list, penalty: penalty)
          end

          test "attaching the same penalty twice is 200 both times with one row" do
            penalty = penalties(:books_one_year_penalty)

            send_raw(:post, penalties_path, {penalty_id: penalty.id})
            assert_equal true, json[:changed]
            send_raw(:post, penalties_path, {penalty_id: penalty.id})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal false, json[:changed]
            assert_equal 1, ListPenalty.where(list: @list, penalty: penalty).count
          end

          test "attach refuses a dynamic penalty with 422 naming the driving field" do
            send_raw(:post, penalties_path, {penalty_id: penalties(:dynamic_penalty).id})
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "number_of_voters"
          end

          test "attach refuses a music penalty, a user penalty and an unknown id with 422" do
            [penalties(:music_penalty).id, penalties(:user_penalty).id, 2_000_000_000].each do |id|
              assert_no_difference -> { ListPenalty.count } do
                send_raw(:post, penalties_path, {penalty_id: id})
                assert_response :unprocessable_entity, id.to_s
              end
            end
          end

          test "attach with a missing or wrongly typed penalty_id is 400" do
            [{}, {penalty_id: "abc"}, {penalty_id: 1.5}, {penalty_id: nil}, {penalty_id: 1, extra: 2}].each do |bad|
              send_raw(:post, penalties_path, bad)
              assert_response bad.key?(:extra) ? :unprocessable_entity : :bad_request, bad.inspect
            end
          end

          test "attach with a read token is 403" do
            assert_no_difference -> { ListPenalty.count } do
              send_raw(:post, penalties_path, {penalty_id: penalties(:books_one_year_penalty).id}, token: READ)
              assert_response :forbidden
            end
          end

          test "detach removes the link and answers with the list and changed" do
            penalty = penalties(:static_penalty)

            send_raw(:delete, penalties_path(penalty.id))
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal true, json[:changed]
            assert_not_includes json[:data][:penalties].map { |p| p[:id] }, penalty.id
            assert_not ListPenalty.exists?(list: @list, penalty: penalty)
          end

          test "detaching a penalty that is not attached is 200 with changed false" do
            send_raw(:delete, penalties_path(penalties(:books_one_year_penalty).id))
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal false, json[:changed]
          end

          test "detach with a read token is 403 and keeps the link" do
            assert_no_difference -> { ListPenalty.count } do
              send_raw(:delete, penalties_path(penalties(:static_penalty).id), token: READ)
              assert_response :forbidden
            end
          end

          test "penalty routes on a non-books list are 404" do
            music = lists(:music_albums_list)
            send_raw(:post, "/api/v1/admin/lists/#{music.id}/penalties", {penalty_id: penalties(:static_penalty).id})
            assert_response :not_found
          end
        end
      end
    end
  end
end
