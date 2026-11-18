# frozen_string_literal: true

require "test_helper"

class UserLists::Edit::RowsComponentTest < ViewComponent::TestCase
  test "renders the rows container with one row per item" do
    list = user_lists(:regular_user_music_albums_favorites)
    items = list.user_list_items.ordered.to_a
    pagy = Pagy::Offset.new(count: items.size, page: 1, limit: 100)
    render_inline(UserLists::Edit::RowsComponent.new(user_list: list, items: items, pagy: pagy))

    assert_selector "div#edit-list-rows"
    assert_selector "#edit-list-rows [data-item-id]", count: items.size
  end

  test "count uses the list noun" do
    list = user_lists(:regular_user_books_read)
    items = list.user_list_items.ordered.to_a
    render_inline(UserLists::Edit::RowsComponent.new(user_list: list, items: items, pagy: Pagy::Offset.new(count: 2, page: 1, limit: 100)))
    assert_selector "[data-testid=item-count]", text: "2 books"

    render_inline(UserLists::Edit::RowsComponent.new(user_list: list, items: items, pagy: Pagy::Offset.new(count: 1, page: 1, limit: 100)))
    assert_selector "[data-testid=item-count]", text: "1 book"
  end

  test "renders an empty state for an empty list" do
    list = user_lists(:regular_user_games_favorites)
    pagy = Pagy::Offset.new(count: 0, page: 1, limit: 100)
    render_inline(UserLists::Edit::RowsComponent.new(user_list: list, items: [], pagy: pagy))

    assert_selector "div#edit-list-rows"
    assert_selector "[data-testid='empty-list']"
  end
end
