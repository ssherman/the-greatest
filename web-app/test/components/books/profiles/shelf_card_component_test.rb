# frozen_string_literal: true

require "test_helper"

class Books::Profiles::ShelfCardComponentTest < ViewComponent::TestCase
  Shelf = Services::Books::Profiles::Library::Shelf
  RatedBook = Services::Books::Profiles::Library::RatedBook

  def empty_shelf = Shelf.new(books: [], total: 0, list: nil)

  def full_shelf
    list = Books::UserList.create!(user: users(:profile_reader), list_type: :favorites,
      name: Books::UserList.default_list_name_for(:favorites))
    Shelf.new(books: [books_books(:war_and_peace)], total: 1, list: list)
  end

  test "owner with an empty primary shelf gets the prompt card" do
    render_inline Books::Profiles::ShelfCardComponent.new(kind: :favorites, shelf: empty_shelf, audience: :owner)

    assert_selector "[data-testid='profile-favorites-prompt'].card-dash a", count: 1
  end

  test "public with an empty or nil primary shelf does not render" do
    [empty_shelf, nil].each do |shelf|
      refute Books::Profiles::ShelfCardComponent.new(kind: :favorites, shelf: shelf, audience: :public).render?
    end
  end

  test "a highest-rated-only card has a card title for both audiences" do
    top = [RatedBook.new(book: books_books(:war_and_peace), rating: 5)]

    [:owner, :public].each do |audience|
      render_inline Books::Profiles::ShelfCardComponent.new(kind: :recently_read, shelf: empty_shelf, top_rated: top, audience: audience)

      assert_selector "h2.card-title", text: "Highest rated"
      assert_no_text "Recently read"
    end
  end

  test "secondary kind with nothing does not render for either audience" do
    [:owner, :public].each do |audience|
      refute Books::Profiles::ShelfCardComponent.new(kind: :recently_read, shelf: empty_shelf, audience: audience).render?
    end
  end

  test "owner sees the shelf with a see-all link; public sees the shelf without one" do
    shelf = full_shelf

    render_inline Books::Profiles::ShelfCardComponent.new(kind: :favorites, shelf: shelf, audience: :owner)
    assert_selector "[data-testid='profile-book']", count: 1
    assert_selector "a[href='/my/lists/#{shelf.list.id}']"

    render_inline Books::Profiles::ShelfCardComponent.new(kind: :favorites, shelf: shelf, audience: :public)
    assert_selector "[data-testid='profile-book']", count: 1
    assert_no_selector "a[href='/my/lists/#{shelf.list.id}']"
  end

  test "highest rated shares the recently read card and prints ratings without a trailing zero" do
    rated = [RatedBook.new(book: books_books(:war_and_peace), rating: BigDecimal("4.0"))]

    render_inline Books::Profiles::ShelfCardComponent.new(
      kind: :recently_read, shelf: empty_shelf, top_rated: rated, audience: :public
    )

    assert_selector "[data-testid='profile-top-rated'] [data-testid='profile-book']", text: "4"
    assert_no_text "4.0"
  end

  test "see all points at the visitor list only when linkable, and never builds a path without a list" do
    list = Books::UserList.create!(user: users(:profile_reader), list_type: :favorites,
      name: Books::UserList.default_list_name_for(:favorites))
    shelf = Services::Books::Profiles::Library::Shelf.new(books: [books_books(:war_and_peace)], total: 1, list: list)

    render_inline Books::Profiles::ShelfCardComponent.new(kind: :favorites, shelf: shelf, audience: :public, data: stub(linkable?: true))
    assert_link "See all (1)", href: "/user_lists/#{list.id}"

    render_inline Books::Profiles::ShelfCardComponent.new(kind: :favorites, shelf: shelf, audience: :public, data: stub(linkable?: false))
    assert_no_link "See all (1)"

    no_list = Services::Books::Profiles::Library::Shelf.new(books: [books_books(:war_and_peace)], total: 1, list: nil)
    render_inline Books::Profiles::ShelfCardComponent.new(kind: :favorites, shelf: no_list, audience: :owner, data: stub(linkable?: true))
    assert_no_link "See all (1)"
  end
end
