# frozen_string_literal: true

require "test_helper"

module Reviews
  class WidgetComponentTest < ViewComponent::TestCase
    setup do
      @book = books_books(:war_and_peace)
    end

    test "carries the polymorphic pair the state endpoint needs" do
      render_inline(Reviews::WidgetComponent.new(reviewable: @book))

      assert_selector "[data-controller='reviews--widget']"
      assert_selector "[data-reviews--widget-reviewable-type-value='Books::Book']"
      assert_selector "[data-reviews--widget-reviewable-id-value='#{@book.id}']"
    end

    test "renders a neutral invitation when no review is given" do
      render_inline(Reviews::WidgetComponent.new(reviewable: @book))

      assert_selector "[data-testid='review-widget-label']", text: "Rate this book"
      assert_no_selector "[data-testid='review-widget-stars']"
    end

    test "renders the rating when a review is given" do
      render_inline(Reviews::WidgetComponent.new(reviewable: @book, review: reviews(:regular_user_war_and_peace)))

      assert_selector "[data-testid='review-widget-stars']"
      assert_selector "[role='img'][aria-label='Your rating: 5 out of 5 stars']"
      assert_selector "[data-testid='review-widget-label']", text: "Edit your review"
    end

    test "the cached render carries no user-specific text" do
      render_inline(Reviews::WidgetComponent.new(reviewable: @book))

      refute_match(/your/i, page.text)
    end

    test "renders a button, not a link" do
      render_inline(Reviews::WidgetComponent.new(reviewable: @book))

      assert_selector "button[type='button'][data-action='click->reviews--widget#open']"
    end
  end
end
