require "test_helper"

class UserListStateControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:regular_user)
    host! Rails.application.config.domains[:music]
  end

  test "anonymous request returns 401 with unauthenticated code" do
    get user_list_state_path, as: :json
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "unauthenticated", body.dig("error", "code")
  end

  test "signed-in request returns lists scoped to music domain" do
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal "music", body["domain"]
    assert_kind_of Integer, body["version"]

    types = body["lists"].map { |l| l["type"] }.uniq
    assert_includes types, "Music::Albums::UserList"
    assert_includes types, "Music::Songs::UserList"
    assert_not_includes types, "Games::UserList"
    assert_not_includes types, "Movies::UserList"
  end

  test "list payload includes id, type, list_type, name, default, icon" do
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    body = JSON.parse(response.body)
    list = body["lists"].find { |l| l["list_type"] == "favorites" && l["type"] == "Music::Albums::UserList" }
    assert list, "Expected a favorites album list"
    %w[id type list_type name default icon].each { |k| assert list.key?(k), "missing #{k}" }
    assert_equal "heart", list["icon"]
    assert_equal true, list["default"]
  end

  test "memberships are keyed by listable_type and listable_id (string), values are {list_id, item_id} tuples" do
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    body = JSON.parse(response.body)

    favs_list = body["lists"].find { |l| l["list_type"] == "favorites" && l["type"] == "Music::Albums::UserList" }
    album = music_albums(:dark_side_of_the_moon)
    fixture_item = user_list_items(:regular_user_fav_album_1)

    entries = body.dig("memberships", "Music::Album", album.id.to_s)
    assert_kind_of Array, entries
    entry = entries.find { |e| e["list_id"] == favs_list["id"] }
    assert entry, "Expected a membership entry for the favorites list"
    assert_equal fixture_item.id, entry["item_id"]
  end

  test "scopes to games subclass on games domain" do
    host! Rails.application.config.domains[:games]
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    body = JSON.parse(response.body)
    assert_equal "games", body["domain"]
    types = body["lists"].map { |l| l["type"] }.uniq
    assert_equal ["Games::UserList"], types
  end

  test "scopes to movies subclass on movies domain" do
    host! Rails.application.config.domains[:movies]
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    body = JSON.parse(response.body)
    assert_equal "movies", body["domain"]
    types = body["lists"].map { |l| l["type"] }.uniq
    assert_equal ["Movies::UserList"], types
  end

  test "Cache-Control header prevents caching" do
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    assert_includes response.headers["Cache-Control"].to_s, "no-store"
    assert_includes response.headers["Cache-Control"].to_s, "private"
  end

  test "version reflects user.updated_at" do
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    body = JSON.parse(response.body)
    assert_equal @user.reload.updated_at.to_i, body["version"]
  end

  test "response includes a CSRF token for client-side mutations" do
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    body = JSON.parse(response.body)
    assert body["csrf_token"].is_a?(String)
    assert_predicate body["csrf_token"], :present?
  end

  test "response includes user_id so the JS cache can bind to identity" do
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    body = JSON.parse(response.body)
    assert_equal @user.id, body["user_id"]
  end

  test "backfills tg_uid cookie for sessions established before the cookie shipped" do
    sign_in_as(@user, stub_auth: true)
    cookies.delete(:tg_uid)
    get user_list_state_path, as: :json
    assert_response :success
    assert_equal @user.id.to_s, cookies[:tg_uid]
  end
end
