# frozen_string_literal: true

require "test_helper"

module Reviews
  class SummaryLineComponentTest < ViewComponent::TestCase
    test "prints the average, the rating count and the review count" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:war_and_peace)))

      assert_text "4.3"
      # Word-boundary regexes, not plain substrings: "3 ratings" is itself a substring
      # of a corrupted "13 ratings", and "1 rating" (see below) is a substring of the
      # wrongly-pluralized "1 ratings" -- a bare `assert_text "1 rating"` would pass
      # against that regression. The trailing \b fails to match between "g" and "s" in
      # "ratings", which is exactly what pins the singular form.
      assert_text(/\b3 ratings\b/)
      assert_text(/\b2 reviews\b/)
    end

    test "omits the review count when nothing is written" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:crime_and_punishment)))

      assert_text(/\b1 rating\b/)
      # Scoped to the counts span, not a page-wide text assertion: the link also
      # carries an sr-only "Jump to ratings and reviews" destination string, and
      # "reviews" there matches both a plain substring check for "review" and even a
      # word-boundary /\breviews?\b/ (confirmed: "Jump to ratings and
      # reviews" =~ /\breviews?\b/ is truthy) -- a page-wide assertion has no way to
      # tell that legitimate sr-only text apart from a real review-count leak. Scoping
      # to [data-testid='review-summary-counts'] excludes the sr-only span entirely, so
      # the singular/plural review-count phrase can be pinned absent without a false
      # positive against unrelated text.
      assert_no_selector "[data-testid='review-summary-counts']", text: /\breviews?\b/
    end

    test "labels the stars with the average" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:war_and_peace)))

      assert_selector "[role='img'][aria-label='Average rating 4.3 out of 5 stars']"
    end

    test "links down to the reviews card" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:war_and_peace)))

      assert_selector "a[href='#ratings-reviews'][data-testid='review-summary-line']"
    end

    test "hides the duplicate visible number from the accessible name" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:war_and_peace)))

      # The stars' aria-label already speaks "4.3" -- without aria-hidden here a screen
      # reader would hear the average twice with nothing between the two readings.
      assert_selector "a[data-testid='review-summary-line'] > span[aria-hidden='true']", text: "4.3"
    end

    test "gives the link a destination in its accessible name" do
      render_inline(Reviews::SummaryLineComponent.new(summary: review_summaries(:war_and_peace)))

      assert_selector "a[data-testid='review-summary-line'] > .sr-only", text: "Jump to ratings and reviews"
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
