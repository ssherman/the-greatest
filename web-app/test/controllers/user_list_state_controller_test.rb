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
    cookies[:tg_uid] = ""
    assert cookies[:tg_uid].blank?
    get user_list_state_path, as: :json
    assert_response :success
    assert_equal @user.id.to_s, cookies[:tg_uid]
  end

  test "state endpoint backfills missing default lists for the current domain" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    assert_difference -> { @user.user_lists.where(type: "Books::UserList").count }, 2 do
      get user_list_state_path, as: :json
    end

    body = JSON.parse(response.body)
    assert_equal "books", body["domain"]
    assert_equal ["Books::UserList"], body["lists"].map { |l| l["type"] }.uniq
  end

  test "includes membership status" do
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    membership = JSON.parse(response.body)["membership"]
    assert_equal true, membership["member"]
    assert_equal "monthly", membership["plan"]
    assert_equal "stripe", membership["source"]
    assert_equal memberships(:regular_user_monthly).current_period_end.iso8601, membership["current_period_end"]

    non_member = users(:admin_user)
    non_member.memberships.destroy_all
    sign_in_as(non_member, stub_auth: true)
    get user_list_state_path, as: :json
    membership = JSON.parse(response.body)["membership"]
    assert_equal false, membership["member"]
    assert_nil membership["current_period_end"]
  end

  test "sends an ETag and answers 304 when it matches" do
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    etag = response.headers["ETag"]
    assert etag.present?

    get user_list_state_path, as: :json, headers: {"If-None-Match" => etag}
    assert_response :not_modified
    assert_empty response.body
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "the ETag changes when an item is added, an item is removed, and a list is created" do
    sign_in_as(@user, stub_auth: true)
    etag = -> {
      get user_list_state_path, as: :json
      response.headers["ETag"]
    }
    before = etag.call

    list = @user.user_lists.where(type: "Music::Albums::UserList").order(:id).first
    item = list.user_list_items.create!(listable: music_albums(:abbey_road))
    after_add = etag.call
    assert_not_equal before, after_add

    item.destroy!
    after_remove = etag.call
    assert_not_equal after_add, after_remove

    Music::Albums::UserList.create!(user: @user, name: "Extra", list_type: :custom)
    assert_not_equal after_remove, etag.call
  end

  test "the ETag changes when membership is granted and when it expires" do
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)
    etag = -> {
      get user_list_state_path, as: :json
      response.headers["ETag"]
    }
    before = etag.call

    user.memberships.create!(source: :stripe, status: :canceled, interval: :monthly,
      stripe_subscription_id: "sub_etag_test", current_period_end: 2.hours.from_now)
    granted = etag.call
    assert_not_equal before, granted

    travel 3.hours do
      assert_not_equal granted, etag.call
    end
  end

  test "a 304 still renews a session last active over a day ago" do
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    etag = response.headers["ETag"]

    travel 2.days do
      get user_list_state_path, as: :json, headers: {"If-None-Match" => etag}
      assert_response :not_modified
      assert_in_delta Time.current.to_i, Session.where(user: @user).maximum(:last_active_at).to_i, 5
    end
  end

  test "the ETag does not depend on the CSRF token" do
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    first = response.headers["ETag"]

    reset!
    host! Rails.application.config.domains[:music]
    sign_in_as(@user, stub_auth: true)
    get user_list_state_path, as: :json
    assert_equal first, response.headers["ETag"]
  end
end
