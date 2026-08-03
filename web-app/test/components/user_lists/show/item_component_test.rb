# frozen_string_literal: true

require "test_helper"

class UserLists::Show::ItemComponentTest < ViewComponent::TestCase
  Component = UserLists::Show::ItemComponent

  test "table_layout? is false for card-capable listables outside table_view" do
    refute Component.table_layout?(listable_class: "Music::Album", view_mode: "list_view")
    refute Component.table_layout?(listable_class: "Games::Game", view_mode: "grid_view")
  end

  test "table_layout? is true in table_view for every listable" do
    assert Component.table_layout?(listable_class: "Music::Album", view_mode: "table_view")
    assert Component.table_layout?(listable_class: "Games::Game", view_mode: "table_view")
  end

  test "table_layout? is true for cardless listables in any view_mode" do
    assert Component.table_layout?(listable_class: "Music::Song", view_mode: "list_view")
    assert Component.table_layout?(listable_class: "Movies::Movie", view_mode: "grid_view")
  end

  test "renders a generic table row for an album in table_view" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(Component.new(item: item, view_mode: "table_view", position: 1))

    assert_selector "tr td", text: item.listable.title
    assert_selector "tr[data-listable-id='#{item.listable_id}']"
  end

  test "renders the completed_on badge on a completed_on_enabled list" do
    item = user_list_items(:regular_user_listened_album_1)
    render_inline(Component.new(item: item, view_mode: "table_view", position: 1))

    assert_text "February 01, 2026"
  end

  test "renders an album card (not a row) in grid_view" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(Component.new(item: item, view_mode: "grid_view", position: 1))

    assert_no_selector "tr"
    assert_selector "div.card[data-listable-id='#{item.listable_id}']"
  end

  test "renders a list row with the description in list_view for an album" do
    item = user_list_items(:regular_user_fav_album_2)
    album = item.listable
    description = album.descriptions.create!(
      kind: :summary, locale: "en", source: :ai_generated,
      content: "A landmark concept album about madness and time."
    )
    render_inline(Component.new(item: item, view_mode: "list_view", position: 4))

    assert_no_selector "tr"
    assert_no_selector "div.card"
    assert_text description.content
    assert_text "4." # the position number in the heading
    assert_selector "[data-listable-id='#{album.id}']"
  end

  test "table_layout? is false for books outside table_view" do
    refute Component.table_layout?(listable_class: "Books::Book", view_mode: "list_view")
    refute Component.table_layout?(listable_class: "Books::Book", view_mode: "grid_view")
  end

  test "card_capable? is true for books" do
    assert Component.card_capable?("Books::Book")
  end

  test "grid_container_class gives books the dense books grid" do
    assert_equal Books::CardComponent::GRID_CONTAINER_CLASS,
      Component.grid_container_class("Books::Book")
    assert_equal Books::CardComponent::GRID_CONTAINER_CLASS,
      Component.grid_container_class(Books::Book)
  end

  test "grid_container_class gives every other listable the shared four-column grid" do
    assert_equal Component::DEFAULT_GRID_CONTAINER_CLASS,
      Component.grid_container_class("Music::Album")
    assert_equal Component::DEFAULT_GRID_CONTAINER_CLASS,
      Component.grid_container_class("Games::Game")
  end

  test "renders a book card in grid_view" do
    item = user_list_items(:regular_user_books_item_1)
    render_inline(Component.new(item: item, view_mode: "grid_view", position: 1))

    assert_no_selector "tr"
    assert_selector "div.card[data-listable-id='#{item.listable_id}']"
  end

  test "grid_view passes the item's position through as a cover-loading index" do
    item = user_list_items(:regular_user_books_item_1)

    # Position 7 is past the eager cutoff, so the cover must lazy-load. Without a
    # real index every card in a 100-item grid would fetch eagerly at high priority.
    render_inline(Component.new(item: item, view_mode: "grid_view", position: 7))
    assert_no_selector "img[loading='eager']"

    render_inline(Component.new(item: item, view_mode: "grid_view", position: 1))
    assert_no_selector "img[loading='eager'][fetchpriority='auto']"
  end

  test "renders the book title, author by-line and publication year in list_view" do
    item = user_list_items(:regular_user_books_item_1)
    render_inline(Component.new(item: item, view_mode: "list_view", position: 1))

    assert_selector "a[href='/book/war-and-peace']", text: "War and Peace"
    assert_text "Leo Tolstoy"
    assert_text "1869"
  end

  test "renders a book table row in table_view with authors and year" do
    item = user_list_items(:regular_user_books_item_1)
    render_inline(Component.new(item: item, view_mode: "table_view", position: 1))

    assert_selector "tr td", text: "War and Peace"
    assert_selector "tr td", text: "Leo Tolstoy"
    assert_selector "tr td", text: "1869"
  end
end
