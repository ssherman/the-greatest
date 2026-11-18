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
    assert_selector "input[name='user_list_item[position]'][value='7']", visible: :all
    assert_selector "input[type=number][min='1'][max='7'][required]"
    assert_no_selector "[data-action='user-list-completion#open']"
  end

  test "a completion list offers a Set date opener with the row variant" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(UserLists::Edit::RowComponent.new(item: item))

    assert_selector "button[data-action='user-list-completion#open'][data-variant=row][data-completed-on='2026-01-20']", text: "Set finished date…"
  end
end
