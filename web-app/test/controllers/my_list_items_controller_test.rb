require "test_helper"

class MyListItemsControllerTest < ActionDispatch::IntegrationTest
  STREAM = "text/vnd.turbo-stream.html"

  setup do
    @user = users(:regular_user)
    @list = user_lists(:regular_user_music_albums_favorites)
    @first = user_list_items(:regular_user_fav_album_1)
    @second = user_list_items(:regular_user_fav_album_2)
    @third = user_list_items(:regular_user_fav_album_3)
    host! Rails.application.config.domains[:music]
  end

  def order
    @list.user_list_items.reload.map(&:id)
  end

  def assert_stream
    assert_equal STREAM, response.media_type
  end

  def assert_rows_morphed
    assert_select "turbo-stream[action=replace][target=edit-list-rows][method=morph]"
  end

  def move(item, position, **extra)
    patch move_my_list_item_path(@list, item), params: {user_list_item: {position: position}}.merge(extra), as: :turbo_stream
  end

  test "move puts the item at the position, morphs the rows, and sets manually_ordered" do
    sign_in_as(@user, stub_auth: true)

    move(@third, 1)

    assert_response :success
    assert_stream
    assert_rows_morphed
    assert_equal [@third.id, @first.id, @second.id], order
    assert @list.reload.manually_ordered
    assert_select "turbo-stream[action=append][target=toast-region]", count: 0
  end

  test "move onto another page toasts the new position" do
    sign_in_as(@user, stub_auth: true)

    move(@first, 3)

    assert_response :success
    assert_equal [@second.id, @third.id, @first.id], order
    assert_select "turbo-stream[action=append][target=toast-region]", count: 0

    stub_const_limit(2) do
      move(@second, 3, page: 1)
    end
    assert_response :success
    assert_select "turbo-stream[action=append][target=toast-region]", text: /Moved to #3/
  end

  test "move past the end answers 422 with a toast and changes nothing" do
    sign_in_as(@user, stub_auth: true)

    move(@first, 4)

    assert_response :unprocessable_entity
    assert_stream
    assert_rows_morphed
    assert_select "turbo-stream[target=toast-region] .alert-error"
    assert_equal [@first.id, @second.id, @third.id], order
    refute @list.reload.manually_ordered
  end

  test "a radix-prefixed position is rejected rather than read as hex" do
    sign_in_as(@user, stub_auth: true)

    move(@first, "0x2")

    assert_response :unprocessable_entity
    assert_equal [@first.id, @second.id, @third.id], order
  end

  test "a zero-padded position is read as decimal" do
    sign_in_as(@user, stub_auth: true)

    move(@first, "02")

    assert_response :success
    assert_equal [@second.id, @first.id, @third.id], order
  end

  test "move with a non-integer position answers 422" do
    sign_in_as(@user, stub_auth: true)

    move(@first, "abc")
    assert_response :unprocessable_entity
    assert_stream
    assert_rows_morphed

    patch move_my_list_item_path(@list, @first), params: {}, as: :turbo_stream
    assert_response :unprocessable_entity
    assert_equal [@first.id, @second.id, @third.id], order
  end

  test "move of an item from another user's list 404s as a turbo stream" do
    sign_in_as(users(:contractor_user), stub_auth: true)

    move(@first, 2)

    assert_response :not_found
    assert_stream
    assert_select "turbo-stream[target=toast-region]"
    assert_select "turbo-stream[target=edit-list-rows]", count: 0
  end

  test "move of a removed item 404s as a turbo stream with the rows morphed" do
    sign_in_as(@user, stub_auth: true)
    @second.destroy!

    move(@second, 1)

    assert_response :not_found
    assert_stream
    assert_rows_morphed
    assert_select "turbo-stream[target=toast-region] .alert-error"
  end

  test "destroy removes the item and offers Undo carrying its position and date" do
    sign_in_as(@user, stub_auth: true)

    delete my_list_item_path(@list, @second), params: {page: 1}, as: :turbo_stream

    assert_response :success
    assert_stream
    assert_rows_morphed
    assert_equal [@first.id, @third.id], order
    assert_select "turbo-stream[target=toast-region]" do
      assert_select "form[action=?]", restore_my_list_item_path(@list)
      assert_select "input[name=listable_id][value=?]", @second.listable_id.to_s
      assert_select "input[name=position][value=2]"
      assert_select "input[name=completed_on][value=?]", "2026-03-15"
      assert_select "input[name=added_at]"
      assert_select "input[name=page][value=1]"
    end
  end

  test "the streamed rows carry the new item count after a remove and after a restore" do
    sign_in_as(@user, stub_auth: true)

    delete my_list_item_path(@list, @second), as: :turbo_stream
    assert_select "turbo-stream[target=edit-list-rows] template [data-testid=item-count]", text: "2 albums"

    post restore_my_list_item_path(@list), params: {listable_id: @second.listable_id, position: 2}, as: :turbo_stream
    assert_select "turbo-stream[target=edit-list-rows] template [data-testid=item-count]", text: "3 albums"
  end

  test "destroy escapes the title in the toast" do
    sign_in_as(@user, stub_auth: true)
    @second.listable.update_columns(title: "<b>Bold</b> Album")

    delete my_list_item_path(@list, @second), as: :turbo_stream

    assert_includes response.body, "&lt;b&gt;Bold&lt;/b&gt; Album"
  end

  test "restore puts it back" do
    sign_in_as(@user, stub_auth: true)
    added_at = @second.created_at
    delete my_list_item_path(@list, @second), as: :turbo_stream
    assert_equal [@first.id, @third.id], order

    post restore_my_list_item_path(@list), params: {
      listable_id: @second.listable_id, position: 2, completed_on: "2026-03-15",
      added_at: added_at.iso8601(6), page: 1
    }, as: :turbo_stream

    assert_response :success
    assert_stream
    assert_rows_morphed
    assert_select "turbo-stream[target=toast-region]", text: /Restored/
    restored = @list.user_list_items.reload.find_by(listable_id: @second.listable_id)
    assert_equal [@first.id, restored.id, @third.id], order
    assert_in_delta added_at.to_f, restored.created_at.to_f, 1
    refute @list.reload.manually_ordered
  end

  test "restore when already present answers 422 without a duplicate" do
    sign_in_as(@user, stub_auth: true)

    assert_no_difference -> { UserListItem.count } do
      post restore_my_list_item_path(@list), params: {listable_id: @second.listable_id, position: 1}, as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_stream
    assert_rows_morphed
    assert_select "turbo-stream[target=toast-region] .alert-error"
  end

  test "restore with a missing or garbage position or listable answers 422" do
    sign_in_as(@user, stub_auth: true)
    delete my_list_item_path(@list, @second), as: :turbo_stream

    [
      {listable_id: @second.listable_id},
      {listable_id: @second.listable_id, position: "nope"},
      {position: 1},
      {listable_id: "zzz", position: 1},
      {listable_id: 0, position: 1},
      {listable_id: @second.listable_id, position: 1, completed_on: "not-a-date"}
    ].each do |params|
      post restore_my_list_item_path(@list), params: params, as: :turbo_stream
      assert_response :unprocessable_entity
      assert_stream
    end
    assert_equal [@first.id, @third.id], order
  end

  test "signed-out move answers 401 as a turbo stream" do
    move(@first, 2)

    assert_response :unauthorized
    assert_stream
    assert_select "turbo-stream[target=toast-region] .alert-error"
  end

  test "an invalid CSRF token answers 422 as a turbo stream" do
    sign_in_as(@user, stub_auth: true)
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    patch move_my_list_item_path(@list, @first), params: {authenticity_token: "bogus", user_list_item: {position: 2}}, as: :turbo_stream

    assert_response :unprocessable_entity
    assert_stream
    assert_rows_morphed
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "answers morph the rows to the page the member was on, clamped to the last page" do
    sign_in_as(@user, stub_auth: true)

    move(@first, 2, page: 99)

    assert_response :success
    assert_rows_morphed
    assert_select "[data-item-id]", count: 3
  end

  test "rows in the stream are identical to the Edit page's rows" do
    sign_in_as(@user, stub_auth: true)
    move(@first, 1)
    streamed = Nokogiri::HTML.fragment(Nokogiri::HTML.fragment(response.body).at_css("turbo-stream[target=edit-list-rows] template").inner_html)

    get edit_my_list_path(@list)
    page = Nokogiri::HTML(response.body).at_css("#edit-list-rows")

    assert_equal page.to_html.gsub(/\s+/, " ").strip, streamed.at_css("#edit-list-rows").to_html.gsub(/\s+/, " ").strip
  end

  test "completion lists get a Set date opener on each row and the dialog" do
    sign_in_as(@user, stub_auth: true)
    get edit_my_list_path(user_lists(:regular_user_music_albums_listened))

    assert_select "[data-controller~=user-list-completion]"
    assert_select "dialog#completion-date-dialog"
    assert_select "[data-action='user-list-completion#open'][data-variant=row]"

    get edit_my_list_path(@list)
    assert_select "dialog#completion-date-dialog", count: 0
  end

  test "move works on a games list" do
    host! Rails.application.config.domains[:games]
    sign_in_as(@user, stub_auth: true)
    list = user_lists(:regular_user_games_favorites)
    item = user_list_items(:regular_user_fav_game_1)

    patch move_my_list_item_path(list, item), params: {user_list_item: {position: 1}}, as: :turbo_stream

    assert_response :success
    assert_stream
  end

  private

  def stub_const_limit(limit)
    original = EditPageRows::EDIT_PAGE_LIMIT
    EditPageRows.send(:remove_const, :EDIT_PAGE_LIMIT)
    EditPageRows.const_set(:EDIT_PAGE_LIMIT, limit)
    yield
  ensure
    EditPageRows.send(:remove_const, :EDIT_PAGE_LIMIT)
    EditPageRows.const_set(:EDIT_PAGE_LIMIT, original)
  end
end
