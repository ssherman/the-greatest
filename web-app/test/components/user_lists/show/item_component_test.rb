# frozen_string_literal: true

require "test_helper"

class UserLists::Show::ItemComponentTest < ViewComponent::TestCase
  Component = UserLists::Show::ItemComponent

  test "table_layout? is false for card-capable listables outside table_view" do
    refute Component.table_layout?(listable_class: "Music::Album", view_mode: "grid_view")
    refute Component.table_layout?(listable_class: "Games::Game", view_mode: "grid_view")
  end

  test "table_layout? is true in table_view for every listable" do
    assert Component.table_layout?(listable_class: "Music::Album", view_mode: "table_view")
    assert Component.table_layout?(listable_class: "Games::Game", view_mode: "table_view")
  end

  test "table_layout? is true for cardless listables in any view_mode" do
    assert Component.table_layout?(listable_class: "Music::Song", view_mode: "grid_view")
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

    assert_text "Feb 1, 2026"
  end

  test "renders an album card (not a row) in grid_view" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(Component.new(item: item, view_mode: "grid_view", position: 1))

    assert_no_selector "tr"
    assert_selector "div.card[data-listable-id='#{item.listable_id}']"
  end

  test "an item whose listable is gone renders nothing, in either view, owner or not" do
    [user_list_items(:regular_user_books_item_1), user_list_items(:regular_user_books_item_3), user_list_items(:regular_user_fav_album_1)].each do |item|
      item.update_columns(listable_id: 0)
      item.reload
      %w[grid_view table_view].product([true, false]).each do |view_mode, owner|
        rendered = render_inline(Component.new(item: item, view_mode: view_mode, position: 1, index: 0, completion_editable: owner, owner: owner))

        assert_equal "", rendered.to_html.strip, "#{view_mode} owner #{owner}"
      end
    end
  end

  test "table_layout? is false for books outside table_view" do
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

  # No books fixture ships an attached cover, and without one the card renders a
  # placeholder with no <img> to assert against.
  def attach_cover(book)
    image = Image.new(parent: book, primary: true)
    image.file.attach(io: StringIO.new("fake image data"), filename: "cover.jpg", content_type: "image/jpeg")
    image.save!
    book.reload
  end

  test "grid_view eager-loads covers by page index, not by list position" do
    item = user_list_items(:regular_user_books_item_1)
    attach_cover(item.listable)

    # A ranking-sorted page can put list position 40 first. The cover must still
    # load eagerly, because what matters is where the card sits on the page.
    render_inline(Component.new(item: item, view_mode: "grid_view", position: 40, index: 0))
    assert_selector "img[loading='eager']"

    render_inline(Component.new(item: item, view_mode: "grid_view", position: 1, index: 40))
    assert_selector "img[loading='lazy']"
  end

  test "grid_view falls back to lazy covers when no index is given" do
    item = user_list_items(:regular_user_books_item_1)
    attach_cover(item.listable)

    render_inline(Component.new(item: item, view_mode: "grid_view", position: 1))

    assert_selector "img[loading='lazy']"
  end

  test "a book grid card carries the item's list position as its rank badge" do
    item = user_list_items(:regular_user_books_item_1)
    render_inline(Component.new(item: item, view_mode: "grid_view", position: 12, index: 11))

    assert_selector "div.card .badge", text: "#12"
  end

  test "renders a book table row in table_view with authors and year" do
    item = user_list_items(:regular_user_books_item_1)
    render_inline(Component.new(item: item, view_mode: "table_view", position: 1))

    assert_selector "tr td", text: "War and Peace"
    assert_selector "tr td", text: "Leo Tolstoy"
    assert_selector "tr td", text: "1869"
  end

  test "grid view renders no completion buttons" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(Component.new(item: item, view_mode: "grid_view", position: 1, completion_editable: true))

    assert_no_selector "button", text: /completion date/i
    assert_no_selector "button[data-action='user-list-completion#open']"
    assert_text "Finished"
  end

  test "table view renders the editable date trigger only for the owner" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(Component.new(item: item, view_mode: "table_view", position: 1, completion_editable: true))
    assert_selector "button[data-action='user-list-completion#open'][data-variant='table'][data-item-id='#{item.id}']"

    render_inline(Component.new(item: item, view_mode: "table_view", position: 1))
    assert_no_selector "button[data-action='user-list-completion#open']"
  end

  # "Not yet reviewed" on a provisional book, for the owner only

  def provisional_item
    item = user_list_items(:regular_user_books_item_1)
    item.listable.update_columns(provisional: true)
    item
  end

  test "the owner sees Not yet reviewed on a provisional book in the table layout" do
    render_inline(Component.new(item: provisional_item, view_mode: "table_view", position: 1, owner: true))

    assert_selector "tr [data-testid='not-yet-reviewed']", text: "Not yet reviewed"
  end

  test "the owner sees Not yet reviewed on a provisional book in the grid layout" do
    render_inline(Component.new(item: provisional_item, view_mode: "grid_view", position: 1, owner: true))

    assert_selector "[data-testid='not-yet-reviewed']", text: "Not yet reviewed"
  end

  test "a viewer who is not the owner never sees it" do
    ["table_view", "grid_view"].each do |mode|
      render_inline(Component.new(item: provisional_item, view_mode: mode, position: 1))
      assert_no_selector "[data-testid='not-yet-reviewed']"
    end
  end

  test "a reviewed book shows no badge to the owner" do
    item = user_list_items(:regular_user_books_item_1)
    ["table_view", "grid_view"].each do |mode|
      render_inline(Component.new(item: item, view_mode: mode, position: 1, owner: true))
      assert_no_selector "[data-testid='not-yet-reviewed']"
    end
  end

  test "a provisional album is never badged" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(Component.new(item: item, view_mode: "table_view", position: 1, owner: true))

    assert_no_selector "[data-testid='not-yet-reviewed']"
  end
end
