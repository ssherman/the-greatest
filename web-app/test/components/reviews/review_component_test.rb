# frozen_string_literal: true

require "test_helper"

module Reviews
  class ReviewComponentTest < ViewComponent::TestCase
    setup do
      @review = reviews(:regular_user_war_and_peace)
    end

    test "renders the rating as stars" do
      render_inline(Reviews::ReviewComponent.new(review: @review))

      assert_selector "[role='img'][aria-label='Rated 5 out of 5 stars']"
    end

    test "renders the title when there is one" do
      render_inline(Reviews::ReviewComponent.new(review: @review))

      assert_text "A monumental achievement"
    end

    test "omits the title heading when there is none" do
      render_inline(Reviews::ReviewComponent.new(review: reviews(:editor_user_war_and_peace)))

      assert_no_selector "[data-testid='review-title']"
    end

    test "renders the stored body as markup rather than escaping it" do
      render_inline(Reviews::ReviewComponent.new(review: @review))

      assert_selector "[data-testid='review-body'] p", text: "Worth every one of its twelve hundred pages."
    end

    test "renders a machine-readable timestamp alongside the relative time" do
      render_inline(Reviews::ReviewComponent.new(review: @review))

      assert_selector "time[datetime='#{@review.created_at.iso8601}']"
      assert_text "ago"
    end

    test "keeps a spoiler span so the reveal controller has something to find" do
      @review.update!(body: "<p>He <spoiler>dies</spoiler>.</p>")

      render_inline(Reviews::ReviewComponent.new(review: @review))

      assert_selector "span.review-spoiler", text: "dies"
    end

    test "does not attribute the review to its author" do
      render_inline(Reviews::ReviewComponent.new(review: @review))

      refute_includes rendered_content, @review.user.email
    end
  end
end
