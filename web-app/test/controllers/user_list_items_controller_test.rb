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
    assert_nil body.dig("user_list_item", "completed_on")
    assert_equal [], body.fetch("removed_user_list_items")
    assert body.fetch("message").present?
  end

  test "adding Reading book to Read removes Reading and returns both membership changes" do
    read_list = user_lists(:regular_user_books_read)
    reading_list = Books::UserList.find_or_create_by!(user: @user, list_type: :reading) do |list|
      list.name = Books::UserList.default_list_name_for(:reading)
    end
    reading_item = reading_list.user_list_items.create!(listable: books_books(:cannery_row))

    sign_in_as(@user, stub_auth: true)
    post user_list_items_path(read_list), params: {
      user_list_item: {listable_id: books_books(:cannery_row).id}
    }, as: :json

    assert_response :created
    body = response.parsed_body
    assert_equal Date.current.iso8601, body.dig("user_list_item", "completed_on")
    assert_equal [reading_item.id], body.fetch("removed_user_list_items").pluck("id")
    assert_includes body.fetch("message"), "completed today"
  end

  test "direct Read add explains how to make the book count" do
    sign_in_as(@user, stub_auth: true)

    post user_list_items_path(user_lists(:regular_user_books_read)), params: {
      user_list_item: {listable_id: books_books(:cannery_row).id}
    }, as: :json

    assert_response :created
    assert_nil response.parsed_body.dig("user_list_item", "completed_on")
    assert_includes response.parsed_body.fetch("message"), "Books I've Read"
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
    body = response.parsed_body
    assert_equal true, body.fetch("ok")
    assert_equal item.id, body.dig("removed_user_list_item", "id")
    assert body.fetch("message").present?
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

  test "completion update is owner-only and only accepts completed_on" do
    sign_in_as(@user, stub_auth: true)
    item = user_list_items(:regular_user_books_item_3)

    patch user_list_item_completion_path(item), params: {
      user_list_item: {completed_on: "2025-03-04", position: 999}
    }

    assert_response :see_other
    assert_redirected_to my_list_path(item.user_list)
    assert_equal Date.new(2025, 3, 4), item.reload.completed_on
    refute_equal 999, item.position
  end

  test "completion update returns 404 for another user's item" do
    other_read_list = Books::UserList.create!(
      user: @other_user,
      name: Books::UserList.default_list_name_for(:read),
      list_type: :read
    )
    other_item = other_read_list.user_list_items.create!(listable: books_books(:cannery_row))

    sign_in_as(@user, stub_auth: true)
    patch user_list_item_completion_path(other_item), params: {
      user_list_item: {completed_on: "2025-03-04"}
    }

    assert_response :not_found
  end

  test "invalid completion date redirects with an alert and leaves the item unchanged" do
    sign_in_as(@user, stub_auth: true)
    item = user_list_items(:regular_user_books_item_3)
    original_completed_on = item.completed_on

    patch user_list_item_completion_path(item), params: {
      user_list_item: {completed_on: "March 4, 2025"}
    }

    assert_response :see_other
    assert_redirected_to my_list_path(item.user_list)
    assert_equal "Completion date is invalid", flash[:alert]
    assert_equal original_completed_on, item.reload.completed_on
  end

  test "completion update rejects a list without completion dates" do
    sign_in_as(@user, stub_auth: true)
    item = user_list_items(:regular_user_books_item_1)

    patch user_list_item_completion_path(item), params: {
      user_list_item: {completed_on: "2025-03-04"}
    }

    assert_response :see_other
    assert_equal "Completion dates are not enabled for this list", flash[:alert]
    assert_nil item.reload.completed_on
  end
end
