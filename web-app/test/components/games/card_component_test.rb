# frozen_string_literal: true

require "test_helper"

class Games::CardComponentTest < ViewComponent::TestCase
  setup do
    @game = games_games(:breath_of_the_wild)
  end

  test "requires one of game, ranked_item or list_item" do
    error = assert_raises(ArgumentError) { Games::CardComponent.new }

    assert_equal "Must provide either game:, ranked_item:, or list_item:", error.message
  end

  test "carries the polymorphic pair the list widget needs" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_selector "[data-listable-type='Games::Game'][data-listable-id='#{@game.id}']"
  end

  test "links to the game and breaks out of any enclosing turbo frame" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_selector "a[href='/game/#{@game.slug}'][data-turbo-frame='_top']"
  end

  test "renders the title and release year" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_selector "h2.card-title", text: @game.title
    assert_selector ".card-body", text: /\b2017\b/
  end

  test "names the developer, not every associated company" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_selector "p", text: "by Nintendo"
  end

  test "shows a placeholder when the game has no image" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_selector "figure", text: "No Image"
    assert_no_selector "figure img"
  end

  test "shows no rank badge when rendered from a bare game" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_no_selector ".badge-primary"
  end

  test "shows the rank badge when rendered from a ranked item" do
    render_inline(Games::CardComponent.new(ranked_item: ranked_items(:games_ranked_botw)))

    # Anchored so a bare "#1" cannot match a corrupted "#12". normalize_ws is
    # required: default_normalize_ws is false and the badge's raw text is
    # "\n          #1\n        ", which no anchored regex matches (verified).
    assert_selector ".badge-primary", text: /\A#1\z/, normalize_ws: true
    assert_selector "h2.card-title", text: @game.title
  end

  test "uses the list item position as the rank when given one" do
    # list_items(:games_item) is breath_of_the_wild at position 1 (verified).
    render_inline(Games::CardComponent.new(list_item: list_items(:games_item)))

    assert_selector ".badge-primary", text: /\A#1\z/, normalize_ws: true
  end
end
