require "test_helper"

class UserListItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:regular_user)
    @other_user = users(:editor_user)
    @list = user_lists(:regular_user_music_albums_favorites)
    @other_list = user_lists(:admin_user_games_favorites)
    @album = music_albums(:wish_you_were_here)
    @existing_album = music_albums(:dark_side_of_the_moon)
    host! Rails.application.config.domains[:music]
  end

  test "anonymous create returns 401" do
    post user_list_items_path(@list),
      params: {user_list_item: {listable_id: @album.id}}, as: :json
    assert_response :unauthorized
  end

  test "owner can add an item" do
    sign_in_as(@user, stub_auth: true)
    assert_difference "UserListItem.count", 1 do
      post user_list_items_path(@list),
        params: {user_list_item: {listable_id: @album.id}}, as: :json
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal @album.id, body.dig("user_list_item", "listable_id")
    assert_equal "Music::Album", body.dig("user_list_item", "listable_type")
    assert_equal @list.id, body.dig("user_list_item", "user_list_id")
    assert body.dig("user_list_item", "position").positive?
  end

  test "duplicate add returns 409 conflict" do
    sign_in_as(@user, stub_auth: true)
    post user_list_items_path(@list),
      params: {user_list_item: {listable_id: @existing_album.id}}, as: :json
    assert_response :conflict
    assert_equal "conflict", JSON.parse(response.body).dig("error", "code")
  end

  test "wrong-type listable returns 422 validation_failed" do
    # Force the controller's listable lookup to return a Music::Song so the
    # listable_type_compatible_with_user_list validation rejects it on save.
    sign_in_as(@user, stub_auth: true)
    song = music_songs(:time)
    Music::Album.stubs(:find).returns(song)
    post user_list_items_path(@list),
      params: {user_list_item: {listable_id: song.id}}, as: :json
    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body).dig("error", "code")
  end

  test "non-owner of list returns 404 (existence hidden)" do
    sign_in_as(@user, stub_auth: true) # @user does not own @other_list
    post user_list_items_path(@other_list),
      params: {user_list_item: {listable_id: @album.id}}, as: :json
    assert_response :not_found
  end

  test "owner can destroy an item" do
    sign_in_as(@user, stub_auth: true)
    item = user_list_items(:regular_user_fav_album_1)
    assert_difference "UserListItem.count", -1 do
      delete user_list_item_path(@list, item), as: :json
    end
    assert_response :success
    assert_equal({"ok" => true}, JSON.parse(response.body))
  end

  test "destroy returns 404 for non-owner" do
    sign_in_as(@user, stub_auth: true)
    other_item = user_list_items(:regular_user_fav_album_1)
    delete user_list_item_path(@other_list, other_item), as: :json
    assert_response :not_found
  end

  test "destroy returns 404 for missing item" do
    sign_in_as(@user, stub_auth: true)
    delete user_list_item_path(@list, 99_999_999), as: :json
    assert_response :not_found
  end

  test "Cache-Control header prevents caching on create" do
    sign_in_as(@user, stub_auth: true)
    post user_list_items_path(@list),
      params: {user_list_item: {listable_id: @album.id}}, as: :json
    assert_includes response.headers["Cache-Control"].to_s, "no-store"
  end
end
