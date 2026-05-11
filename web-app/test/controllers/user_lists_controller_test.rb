require "test_helper"

class UserListsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:regular_user)
    @album = music_albums(:wish_you_were_here)
    host! Rails.application.config.domains[:music]
  end

  test "anonymous request returns 401" do
    post user_lists_path, params: {user_list: {type: "Music::Albums::UserList", name: "X"}}, as: :json
    assert_response :unauthorized
    assert_equal "unauthenticated", JSON.parse(response.body).dig("error", "code")
  end

  test "creates a custom list and forces list_type to custom" do
    sign_in_as(@user, stub_auth: true)
    assert_difference "Music::Albums::UserList.count", 1 do
      post user_lists_path,
        params: {user_list: {type: "Music::Albums::UserList", name: "Top 50 of the 90s", list_type: "favorites"}},
        as: :json
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "custom", body.dig("user_list", "list_type")
    assert_equal "Music::Albums::UserList", body.dig("user_list", "type")
    assert_equal false, body.dig("user_list", "default")
    assert_nil body["user_list_item"]
  end

  test "atomic create with listable_id creates list AND item" do
    sign_in_as(@user, stub_auth: true)
    assert_difference -> { Music::Albums::UserList.count } => 1, -> { UserListItem.count } => 1 do
      post user_lists_path,
        params: {user_list: {type: "Music::Albums::UserList", name: "Atomic", listable_id: @album.id}},
        as: :json
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal @album.id, body.dig("user_list_item", "listable_id")
    assert_equal "Music::Album", body.dig("user_list_item", "listable_type")
    assert_equal body.dig("user_list", "id"), body.dig("user_list_item", "user_list_id")
  end

  test "transaction rolls back when item creation fails" do
    sign_in_as(@user, stub_auth: true)
    assert_no_difference -> { Music::Albums::UserList.count } do
      assert_no_difference -> { UserListItem.count } do
        post user_lists_path,
          params: {user_list: {type: "Music::Albums::UserList", name: "Will Fail", listable_id: 99_999_999}},
          as: :json
      end
    end
    assert_response :not_found
  end

  test "rejects unknown type" do
    sign_in_as(@user, stub_auth: true)
    post user_lists_path,
      params: {user_list: {type: "User", name: "Bogus"}},
      as: :json
    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body).dig("error", "code")
  end

  test "missing name returns 422 validation_failed" do
    sign_in_as(@user, stub_auth: true)
    post user_lists_path,
      params: {user_list: {type: "Music::Albums::UserList", name: ""}},
      as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body.dig("error", "code")
    assert body.dig("error", "details").present?
  end

  test "Cache-Control header prevents caching" do
    sign_in_as(@user, stub_auth: true)
    post user_lists_path,
      params: {user_list: {type: "Music::Albums::UserList", name: "Cacheless"}},
      as: :json
    assert_includes response.headers["Cache-Control"].to_s, "no-store"
  end
end
