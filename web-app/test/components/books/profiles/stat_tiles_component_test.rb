# frozen_string_literal: true

require "test_helper"

class Books::Profiles::StatTilesComponentTest < ViewComponent::TestCase
  def stats(**overrides)
    Services::Books::Profiles::Library::Stats.new(
      {books_read: 12, read_last_12_months: nil, average_rating: 4.0, ratings_count: 3, reviews_count: nil}.merge(overrides)
    )
  end

  test "owner gets a tile, with a dash, for a nil stat" do
    render_inline Books::Profiles::StatTilesComponent.new(stats: stats, audience: :owner)

    assert_selector "[data-testid='stat-reviews']", text: "—"
    assert_selector "[data-testid='stat-books-read']", text: "12"
  end

  test "public gets no tile for a nil stat" do
    render_inline Books::Profiles::StatTilesComponent.new(stats: stats, audience: :public)

    assert_no_selector "[data-testid='stat-reviews']"
    assert_no_selector "[data-testid='stat-read-last-12-months']"
    assert_selector "[data-testid='stat-books-read']"
  end

  test "the average keeps its trailing zero" do
    render_inline Books::Profiles::StatTilesComponent.new(stats: stats, audience: :owner)

    assert_selector "[data-testid='stat-average-rating']", text: "4.0"
  end

  test "owner with no finish dates is offered a link to the read list" do
    list = Books::UserList.create!(user: users(:profile_reader), list_type: :read,
      name: Books::UserList.default_list_name_for(:read))

    render_inline Books::Profiles::StatTilesComponent.new(stats: stats, audience: :owner, read_list: list)

    assert_selector "[data-testid='stat-read-last-12-months'] a[href='/my/lists/#{list.id}']"
  end

  test "owner with a 12-month count gets no finish-dates link" do
    list = Books::UserList.create!(user: users(:profile_reader), list_type: :read,
      name: Books::UserList.default_list_name_for(:read))

    render_inline Books::Profiles::StatTilesComponent.new(stats: stats(read_last_12_months: 4), audience: :owner, read_list: list)

    assert_no_selector "[data-testid='stat-read-last-12-months'] a"
  end

  test "public with every stat nil does not render" do
    component = Books::Profiles::StatTilesComponent.new(
      stats: stats(books_read: nil, average_rating: nil, ratings_count: nil), audience: :public
    )

    refute component.render?
  end
end
