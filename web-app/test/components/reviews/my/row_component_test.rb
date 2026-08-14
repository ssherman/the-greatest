require "test_helper"

module Reviews
  module My
    class RowComponentTest < ViewComponent::TestCase
      test "a written review shows its snippet and links to the item" do
        review = reviews(:regular_user_war_and_peace)
        render_inline(Reviews::My::RowComponent.new(review: review))
        assert_selector "a[href*='#{review.reviewable.slug}']"
        assert_text "Worth every one of its twelve hundred pages", normalize_ws: true
      end

      test "a rating-only review offers writing one instead of a snippet" do
        render_inline(Reviews::My::RowComponent.new(review: reviews(:regular_user_crime_and_punishment)))
        assert_selector "[data-testid='write-review']"
        assert_no_selector "[data-testid='review-snippet']"
      end

      test "the snippet renders stored markup as markup, not escaped text" do
        review = reviews(:regular_user_war_and_peace)
        render_inline(Reviews::My::RowComponent.new(review: review))
        assert_no_text "<p>", normalize_ws: true
      end

      test "a long unbroken token cannot widen the row" do
        review = reviews(:regular_user_war_and_peace)
        review.update!(body: "a" * 300)
        render_inline(Reviews::My::RowComponent.new(review: review))
        assert_selector "[data-testid='review-snippet'].\\[overflow-wrap\\:anywhere\\]"
      end

      test "the snippet carries the review-body class so reviews.css link/paragraph/blockquote rules apply" do
        review = reviews(:regular_user_war_and_peace)
        render_inline(Reviews::My::RowComponent.new(review: review))
        assert_selector "[data-testid='review-snippet'].review-body"
      end

      test "mounts the spoiler controller on the snippet so a user's own spoiler is revealable" do
        review = reviews(:regular_user_war_and_peace)
        render_inline(Reviews::My::RowComponent.new(review: review))
        assert_selector "[data-testid='review-snippet'][data-controller='reviews--spoiler']"
        assert_selector "[data-testid='review-snippet'][data-action*='click->reviews--spoiler#reveal']"
        assert_selector "[data-testid='review-snippet'][data-action*='keydown->reviews--spoiler#revealOnKey']"
      end

      test "a cover-less book still names itself for a screen reader" do
        review = reviews(:regular_user_crime_and_punishment)
        render_inline(Reviews::My::RowComponent.new(review: review))
        assert_selector "a[href*='#{review.reviewable.slug}'] .sr-only", text: review.reviewable.title
      end
    end
  end
end
