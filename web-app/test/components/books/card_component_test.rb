# frozen_string_literal: true

require "test_helper"

module Books
  class CardComponentTest < ViewComponent::TestCase
    setup do
      @book = books_books(:war_and_peace)
      @ranked_item = RankedItem.create!(
        item: @book, ranking_configuration: ranking_configurations(:books_global), rank: 42, score: 99
      )
    end

    test "renders the rank with a screen-reader label" do
      render_inline(Books::CardComponent.new(ranked_item: @ranked_item, index: 0))

      assert_selector ".badge", text: "#42"
      assert_selector ".sr-only", text: "Rank"
    end

    test "links once to the book detail page" do
      render_inline(Books::CardComponent.new(ranked_item: @ranked_item, index: 0))

      assert_selector "a[href='/book/war-and-peace']", count: 1
    end

    test "renders the publication year" do
      render_inline(Books::CardComponent.new(ranked_item: @ranked_item, index: 0))

      assert_text "1869"
    end

    test "carries listable data attributes for the increment 3 user-list widget" do
      render_inline(Books::CardComponent.new(ranked_item: @ranked_item, index: 0))

      assert_selector "[data-listable-type='Books::Book'][data-listable-id='#{@book.id}']"
    end

    test "renders an aria-hidden placeholder when the book has no cover" do
      render_inline(Books::CardComponent.new(ranked_item: @ranked_item, index: 0))

      assert_selector "[aria-hidden='true']"
      refute_text "No Image"
    end

    test "eagerly loads the first six covers and lazy-loads the rest" do
      assert_equal "eager", Books::CardComponent.new(ranked_item: @ranked_item, index: 5).send(:loading_strategy)
      assert_equal "lazy", Books::CardComponent.new(ranked_item: @ranked_item, index: 6).send(:loading_strategy)
    end
  end
end
