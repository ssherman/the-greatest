# frozen_string_literal: true

require "test_helper"

class UserLists::Edit::RowComponentTest < ViewComponent::TestCase
  test "renders the row root with its position and item id, title, by-line and handle" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(UserLists::Edit::RowComponent.new(item: item))

    assert_selector "div##{ActionView::RecordIdentifier.dom_id(item)}[data-position='#{item.position}'][data-item-id='#{item.id}']"
    assert_text item.listable.title
    assert_selector "[data-sortable-handle][aria-hidden='true']"
  end

  test "shows the finish date on a completion list" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(UserLists::Edit::RowComponent.new(item: item))

    assert_text "Finished Jan 20, 2026"
  end

  test "date sits on the by-line" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(UserLists::Edit::RowComponent.new(item: item))

    assert_selector "p", text: /#{Regexp.escape(item.listable.book_authors.first.author.name)}\s*·\s*Finished Jan 20, 2026/m
  end

  test "shows a faint placeholder when a completion list item has no date" do
    item = user_list_items(:regular_user_books_item_3)
    item.update!(completed_on: nil)
    render_inline(UserLists::Edit::RowComponent.new(item: item))

    assert_text "No finished date"
  end

  test "has no date line on a list without completion dates" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(UserLists::Edit::RowComponent.new(item: item))

    assert_no_text "date"
  end

  test "renders a song row (no cover)" do
    item = user_list_items(:regular_user_fav_song_1)
    render_inline(UserLists::Edit::RowComponent.new(item: item))

    assert_text item.listable.title
  end

  test "escapes a title with markup" do
    item = user_list_items(:regular_user_fav_album_1)
    item.listable.update_columns(title: "<b>Loud</b>")
    render_inline(UserLists::Edit::RowComponent.new(item: item))

    assert_no_selector "b"
  end

  test "the menu and remove button have accessible names and post to the item routes" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(UserLists::Edit::RowComponent.new(item: item, item_count: 7))

    title = item.listable.title
    assert_selector "button[aria-label='Actions for #{title}']"
    assert_selector "button[aria-label='Remove #{title}']"
    assert_selector "form##{ActionView::RecordIdentifier.dom_id(item, :move_bottom)} input[name='user_list_item[position]'][value='7']", visible: :all
    assert_no_selector "[data-action='user-list-completion#open']"
  end

  test "a completion list offers a Set date opener with the row variant" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(UserLists::Edit::RowComponent.new(item: item))

    assert_selector "button[data-action='user-list-completion#open'][data-variant=row][data-completed-on='2026-01-20']", text: "Set finished date…"
  end

  test "menu items are direct li > button children" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(UserLists::Edit::RowComponent.new(item: item, item_count: 7))

    assert_selector "ul.menu > li > button", text: "Move to top"
    assert_selector "ul.menu > li > button", text: "Move to bottom"
    assert_selector "ul.menu > li > button", text: "Move to position…"
    assert_no_selector "ul.menu form"
  end

  test "Move to top targets its hidden form" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(UserLists::Edit::RowComponent.new(item: item, item_count: 7))

    id = ActionView::RecordIdentifier.dom_id(item, :move_top)
    assert_selector "button[form='#{id}']", text: "Move to top"
    assert_selector "form##{id} input[name='user_list_item[position]'][value='1']", visible: :all
  end

  test "Move to position opens the shared dialog with the row's values" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(UserLists::Edit::RowComponent.new(item: item, item_count: 7))

    assert_selector "button[data-action='user-list-position#open'][data-item-id='#{item.id}'][data-position='#{item.position}'][data-max='7']"
  end

  test "the divider is a bare empty separator so daisyUI draws it" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(UserLists::Edit::RowComponent.new(item: item))

    assert_selector "ul.menu > li[role=separator]:empty[aria-hidden=true]:not([class])", visible: :all
  end

  test "renders for a songs list" do
    item = user_list_items(:regular_user_fav_song_1)
    render_inline(UserLists::Edit::RowComponent.new(item: item, item_count: 3))

    assert_selector "ul.menu > li > button", text: "Move to bottom"
  end

  test "one-item list: bottom form posts 1" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(UserLists::Edit::RowComponent.new(item: item, item_count: 1))

    assert_selector "form##{ActionView::RecordIdentifier.dom_id(item, :move_bottom)} input[name='user_list_item[position]'][value='1']", visible: :all
  end
end
