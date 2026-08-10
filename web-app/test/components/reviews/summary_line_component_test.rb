# frozen_string_literal: true

require "test_helper"

module Reviews
  class SummaryLineComponentTest < ViewComponent::TestCase
    test "prints the average, the rating count and the review count" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:war_and_peace)))

      assert_text "4.3"
      assert_text "3 ratings"
      assert_text "2 reviews"
    end

    test "omits the review count when nothing is written" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:crime_and_punishment)))

      assert_text "1 rating"
      assert_no_text "review"
    end

    test "labels the stars with the average" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:war_and_peace)))

      assert_selector "[role='img'][aria-label='Average rating 4.3 out of 5']"
    end

    test "links down to the reviews card" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:war_and_peace)))

      assert_selector "a[href='#ratings-reviews'][data-testid='review-summary-line']"
    end

    test "renders nothing without a summary" do
      render_inline(Reviews::SummaryLineComponent.new(summary: nil))

      assert_no_selector "[data-testid='review-summary-line']"
    end

    test "renders nothing when the summary has no ratings" do
      empty = ReviewSummary.create!(reviewable: books_books(:got))

      render_inline(Reviews::SummaryLineComponent.new(summary: empty))

      assert_no_selector "[data-testid='review-summary-line']"
    end
  end
end
