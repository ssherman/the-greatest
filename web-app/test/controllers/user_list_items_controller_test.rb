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

  test "a non-Books mutation never calls the reading goal invalidator" do
    Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).never
    Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never
    sign_in_as(@user, stub_auth: true)

    post user_list_items_path(@list),
      params: {user_list_item: {listable_id: @album.id}}, as: :json

    assert_response :created
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

  test "moving a stale Reading book preserves an existing Read date without saying completed today" do
    read_list = user_lists(:regular_user_books_read)
    book = books_books(:cannery_row)
    read_list.user_list_items.create!(listable: book, completed_on: Date.new(2020, 1, 2))
    reading_list = Books::UserList.find_or_create_by!(user: @user, list_type: :reading) do |list|
      list.name = Books::UserList.default_list_name_for(:reading)
    end
    reading_list.user_list_items.create!(listable: book)

    sign_in_as(@user, stub_auth: true)
    post user_list_items_path(read_list), params: {user_list_item: {listable_id: book.id}}, as: :json

    assert_response :created
    body = response.parsed_body
    assert_equal "2020-01-02", body.dig("user_list_item", "completed_on")
    assert_equal "Moved to Books I've Read", body.fetch("message")
  end

  test "adding a non-Books completion-capable item does not show reading-goal guidance" do
    listened_list = user_lists(:regular_user_music_albums_listened)

    sign_in_as(@user, stub_auth: true)
    post user_list_items_path(listened_list), params: {
      user_list_item: {listable_id: music_albums(:thriller).id}
    }, as: :json

    assert_response :created
    assert_equal "Added to Albums I've Listened To", response.parsed_body.fetch("message")
  end

  test "adding Read book serializes every same-owner Reading removal" do
    read_list = user_lists(:regular_user_books_read)
    book = books_books(:cannery_row)
    first_reading_list = Books::UserList.find_or_create_by!(user: @user, list_type: :reading) do |list|
      list.name = Books::UserList.default_list_name_for(:reading)
    end
    second_reading_list = Books::UserList.new(user: @user, name: "Second Reading", list_type: :reading)
    second_reading_list.save!(validate: false)
    first_reading_item = first_reading_list.user_list_items.create!(listable: book)
    second_reading_item = second_reading_list.user_list_items.create!(listable: book)

    sign_in_as(@user, stub_auth: true)
    post user_list_items_path(read_list), params: {user_list_item: {listable_id: book.id}}, as: :json

    assert_response :created
    assert_equal [first_reading_item.id, second_reading_item.id].sort,
      response.parsed_body.fetch("removed_user_list_items").pluck("id").sort
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

  test "direct undated Read add does not enqueue reading goal invalidation" do
    Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never
    sign_in_as(@user, stub_auth: true)

    post user_list_items_path(user_lists(:regular_user_books_read)), params: {
      user_list_item: {listable_id: books_books(:cannery_row).id}
    }, as: :json

    assert_response :created
  end

  test "moving Reading to Read invalidates goals for the new completion date" do
    read_list = user_lists(:regular_user_books_read)
    reading_list = Books::UserList.find_or_create_by!(user: @user, list_type: :reading) do |list|
      list.name = Books::UserList.default_list_name_for(:reading)
    end
    book = books_books(:cannery_row)
    reading_list.user_list_items.create!(listable: book)
    Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).with(
      user: @user, old_completed_on: nil, new_completed_on: Date.current, enqueue: false
    ).returns([])

    sign_in_as(@user, stub_auth: true)
    post user_list_items_path(read_list), params: {
      user_list_item: {listable_id: book.id}
    }, as: :json

    assert_response :created
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
    body = response.parsed_body
    assert_equal "validation_failed", body.dig("error", "code")
    assert_equal ["Music::Song is not compatible with Music::Albums::UserList"],
      body.dig("error", "details", "listable_type")
  end

  test "non-duplicate service failure returns base service errors when the candidate is valid" do
    sign_in_as(@user, stub_auth: true)
    Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).never
    Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never
    Services::UserLists::AddItem.stubs(:call).returns(
      Services::UserLists::MutationResult.failure(["Mutation could not be completed"])
    )

    post user_list_items_path(@list),
      params: {user_list_item: {listable_id: @album.id}}, as: :json

    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_equal "validation_failed", body.dig("error", "code")
    assert_equal({"base" => ["Mutation could not be completed"]}, body.dig("error", "details"))
  end

  test "source-transition service failure keeps its error when an existing target is incidentally duplicate" do
    read_list = user_lists(:regular_user_books_read)
    book = books_books(:cannery_row)
    read_list.user_list_items.create!(listable: book)
    reading_list = Books::UserList.find_or_create_by!(user: @user, list_type: :reading) do |list|
      list.name = Books::UserList.default_list_name_for(:reading)
    end
    reading_list.user_list_items.create!(listable: book)
    UserListItem.any_instance.stubs(:destroy!).raises(
      ActiveRecord::RecordNotDestroyed.new("destroy aborted", UserListItem.new)
    )
    Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).never
    Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

    sign_in_as(@user, stub_auth: true)
    post user_list_items_path(read_list), params: {user_list_item: {listable_id: book.id}}, as: :json

    assert_response :unprocessable_entity
    assert_equal({"base" => ["Mutation could not be completed"]},
      response.parsed_body.dig("error", "details"))
  end

  test "matching candidate uniqueness service errors return 409 conflict" do
    @list.user_list_items.create!(listable: @album)
    sign_in_as(@user, stub_auth: true)
    Services::UserLists::AddItem.stubs(:call).returns(
      Services::UserLists::MutationResult.failure(["Listable is already in this list"])
    )

    post user_list_items_path(@list),
      params: {user_list_item: {listable_id: @album.id}}, as: :json

    assert_response :conflict
    assert_equal "conflict", response.parsed_body.dig("error", "code")
  end

  test "concurrent add uniqueness fallback returns 409 conflict" do
    sign_in_as(@user, stub_auth: true)
    Services::UserLists::AddItem.stubs(:call).raises(ActiveRecord::RecordNotUnique.new("duplicate"))

    post user_list_items_path(@list),
      params: {user_list_item: {listable_id: @album.id}}, as: :json

    assert_response :conflict
    assert_equal "conflict", response.parsed_body.dig("error", "code")
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

  test "destroy returns a complete removed tuple and prevents caching" do
    read_list = user_lists(:regular_user_books_read)
    item = read_list.user_list_items.create!(
      listable: books_books(:cannery_row), completed_on: Date.new(2026, 8, 1)
    )

    sign_in_as(@user, stub_auth: true)
    delete user_list_item_path(read_list, item), as: :json

    assert_response :success
    assert_equal({
      "id" => item.id,
      "user_list_id" => read_list.id,
      "listable_type" => "Books::Book",
      "listable_id" => books_books(:cannery_row).id,
      "position" => item.position,
      "completed_on" => "2026-08-01"
    }, response.parsed_body.fetch("removed_user_list_item"))
    assert_includes response.headers["Cache-Control"].to_s, "no-store"
  end

  test "removing a dated Read item invalidates goals for the removed completion date" do
    read_list = user_lists(:regular_user_books_read)
    completed_on = Date.new(2026, 8, 1)
    item = read_list.user_list_items.create!(
      listable: books_books(:cannery_row), completed_on: completed_on
    )
    Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).with(
      user: @user, old_completed_on: completed_on, new_completed_on: nil, enqueue: false
    ).returns([])

    sign_in_as(@user, stub_auth: true)
    delete user_list_item_path(read_list, item), as: :json

    assert_response :success
  end

  test "resolves the Books owner before destroying the dated Read item" do
    read_list = user_lists(:regular_user_books_read)
    completed_on = Date.new(2026, 8, 1)
    item = read_list.user_list_items.create!(
      listable: books_books(:cannery_row), completed_on: completed_on
    )
    Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).with(
      user: @user, old_completed_on: completed_on, new_completed_on: nil, enqueue: false
    ).returns([])

    sign_in_as(@user, stub_auth: true)
    delete user_list_item_path(read_list, item), as: :json

    assert_response :success
    refute UserListItem.exists?(item.id)
  end

  test "destroy service failure returns service errors as 422" do
    item = user_list_items(:regular_user_fav_album_1)
    Services::UserLists::RemoveItem.stubs(:call).returns(
      Services::UserLists::MutationResult.failure(["Mutation could not be completed"])
    )

    sign_in_as(@user, stub_auth: true)
    delete user_list_item_path(@list, item), as: :json

    assert_response :unprocessable_entity
    assert_equal({"base" => ["Mutation could not be completed"]},
      response.parsed_body.dig("error", "details"))
    assert UserListItem.exists?(item.id)
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
    Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).never
    Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

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

  test "clearing a completion date redirects with notice and prevents caching" do
    sign_in_as(@user, stub_auth: true)
    item = user_list_items(:regular_user_books_item_3)

    patch user_list_item_completion_path(item), params: {user_list_item: {completed_on: ""}}

    assert_response :see_other
    assert_equal "Completion date cleared", flash[:notice]
    assert_nil item.reload.completed_on
    assert_includes response.headers["Cache-Control"].to_s, "no-store"
  end

  test "setting a completion date invalidates goals for the new date" do
    item = user_list_items(:regular_user_books_item_3)
    item.update!(completed_on: nil)
    completed_on = Date.new(2025, 3, 4)
    Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).with(
      user: @user, old_completed_on: nil, new_completed_on: completed_on, enqueue: false
    ).returns([])

    sign_in_as(@user, stub_auth: true)
    patch user_list_item_completion_path(item), params: {
      user_list_item: {completed_on: completed_on.iso8601}
    }

    assert_response :see_other
  end

  test "changing a completion date invalidates goals for both dates" do
    item = user_list_items(:regular_user_books_item_3)
    old_completed_on = item.completed_on
    new_completed_on = Date.new(2025, 3, 4)
    Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).with(
      user: @user, old_completed_on: old_completed_on, new_completed_on: new_completed_on, enqueue: false
    ).returns([])

    sign_in_as(@user, stub_auth: true)
    patch user_list_item_completion_path(item), params: {
      user_list_item: {completed_on: new_completed_on.iso8601}
    }

    assert_response :see_other
  end

  test "serializes a Books mutation and URL capture under the owner lock then enqueues afterward" do
    item = user_list_items(:regular_user_books_item_3)
    old_completed_on = item.completed_on
    new_completed_on = Date.new(2025, 3, 4)
    url = "https://books.test/reading_goals/123"
    owner_locked = false
    capture_depth = nil
    connection = ActiveRecord::Base.connection

    sign_in_as(@user, stub_auth: true)
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql]
      owner_locked = true if sql.match?(/FROM "users"/) && sql.include?("FOR UPDATE")
    end
    Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).with do |arguments|
      assert owner_locked, "the owner row must be locked before URL capture"
      assert_equal new_completed_on, item.reload.completed_on
      capture_depth = connection.open_transactions
      arguments == {
        user: @user,
        old_completed_on: old_completed_on,
        new_completed_on: new_completed_on,
        enqueue: false
      }
    end.returns([url])
    Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with do |domain, urls|
      assert_equal "books", domain
      assert_equal [url], urls
      assert_operator capture_depth, :>, connection.open_transactions,
        "enqueue must happen after the owner-lock transaction exits"
      true
    end

    patch user_list_item_completion_path(item), params: {
      user_list_item: {completed_on: new_completed_on.iso8601}
    }

    assert_response :see_other
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "clearing a completion date invalidates goals for the old date" do
    item = user_list_items(:regular_user_books_item_3)
    old_completed_on = item.completed_on
    Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).with(
      user: @user, old_completed_on: old_completed_on, new_completed_on: nil, enqueue: false
    ).returns([])

    sign_in_as(@user, stub_auth: true)
    patch user_list_item_completion_path(item), params: {
      user_list_item: {completed_on: ""}
    }

    assert_response :see_other
  end

  test "updating a completion date redirects with an update notice" do
    sign_in_as(@user, stub_auth: true)
    item = user_list_items(:regular_user_books_item_3)

    patch user_list_item_completion_path(item), params: {user_list_item: {completed_on: "2025-03-04"}}

    assert_response :see_other
    assert_equal "Completion date updated", flash[:notice]
    assert_equal Date.new(2025, 3, 4), item.reload.completed_on
  end
end
