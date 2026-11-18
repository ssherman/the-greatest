# frozen_string_literal: true

require "test_helper"

class UserLists::Edit::PositionDialogComponentTest < ViewComponent::TestCase
  setup do
    @list = user_lists(:regular_user_music_albums_favorites)
  end

  test "has a required number input with min 1 and a page field" do
    render_inline(UserLists::Edit::PositionDialogComponent.new(user_list: @list, page: 2))

    assert_selector "dialog#position-dialog.modal"
    assert_selector "input[type=number][name='user_list_item[position]'][min='1'][required]"
    assert_selector "input[type=hidden][name=page][value='2']", visible: :all
  end

  test "Cancel and Move buttons" do
    render_inline(UserLists::Edit::PositionDialogComponent.new(user_list: @list, page: 1))

    assert_selector "button[data-action='user-list-position#cancel']", text: "Cancel"
    assert_selector "button[type=submit]", text: "Move"
  end
end
