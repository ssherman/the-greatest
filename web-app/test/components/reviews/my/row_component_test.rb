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

      test "every row carries a delete button posting DELETE to that review" do
        review = reviews(:regular_user_war_and_peace)
        render_inline(Reviews::My::RowComponent.new(review: review))

        assert_selector "[data-testid='delete-review']"
        assert_selector "form[action='/reviews/#{review.id}'] input[name='_method'][value='delete']", visible: :all
      end

      # A rating-only row has no body to lose, but it is still a row the owner
      # may want gone -- and it is the row whose primary button says "Write a
      # review", so without its own delete there would be no way to remove it
      # at all short of opening the editor.
      test "a rating-only row can be deleted too" do
        render_inline(Reviews::My::RowComponent.new(review: reviews(:regular_user_crime_and_punishment)))
        assert_selector "[data-testid='delete-review']"
      end

      test "the delete button asks for confirmation and names the book" do
        review = reviews(:regular_user_war_and_peace)
        render_inline(Reviews::My::RowComponent.new(review: review))

        confirm = page.find("form[data-my-reviews-delete]")["data-turbo-confirm"]
        assert_includes confirm, review.reviewable.title
        assert_includes confirm, "cannot be undone"
      end

      # The label must not be the only thing distinguishing this control, and the
      # colour must not be either -- the owner is red-green colour blind, so a
      # bare red icon would be indistinguishable from the neighbouring button.
      test "the delete button is identifiable without relying on colour" do
        review = reviews(:regular_user_war_and_peace)
        render_inline(Reviews::My::RowComponent.new(review: review))

        # normalize_ws because default_normalize_ws is false in this project, so
        # the button's actual text is "\n      Delete\n" and an anchored regex
        # would fail against correct markup. The anchor still matters: without it
        # `text: "Delete"` is a substring match that would pass on "Undelete".
        assert_selector "[data-testid='delete-review']", text: /\ADelete\z/, normalize_ws: true
        assert_match(/Delete your review of #{Regexp.escape(review.reviewable.title)}/,
          page.find("[data-testid='delete-review']")["aria-label"])
      end

      test "the delete form flags whether removing this row empties the page" do
        review = reviews(:regular_user_war_and_peace)

        render_inline(Reviews::My::RowComponent.new(review: review, last_on_page: true))
        assert_selector "form[data-my-reviews-delete-last='true']"

        render_inline(Reviews::My::RowComponent.new(review: review))
        assert_selector "form[data-my-reviews-delete-last='false']"
      end
    end
  end
end
