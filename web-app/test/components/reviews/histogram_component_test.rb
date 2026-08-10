# frozen_string_literal: true

require "test_helper"

module Reviews
  class HistogramComponentTest < ViewComponent::TestCase
    setup do
      @summary = review_summaries(:war_and_peace)
    end

    test "renders one row per star, highest first" do
      render_inline(Reviews::HistogramComponent.new(summary: @summary))

      rows = page.all("[data-testid='histogram-row']").map { |row| row["data-rating"] }
      assert_equal %w[5 4 3 2 1], rows
    end

    test "sizes each bar by that rating's share of all ratings" do
      render_inline(Reviews::HistogramComponent.new(summary: @summary))

      # war_and_peace: 3 ratings -- one 5 (33.3%), two 4s (66.7%), none below.
      assert_selector "[data-testid='histogram-row'][data-rating='5'] [data-testid='histogram-bar'][style*='width: 33.3%']"
      assert_selector "[data-testid='histogram-row'][data-rating='4'] [data-testid='histogram-bar'][style*='width: 66.7%']"
      assert_selector "[data-testid='histogram-row'][data-rating='1'] [data-testid='histogram-bar'][style*='width: 0.0%']"
    end

    test "prints the count for each row" do
      render_inline(Reviews::HistogramComponent.new(summary: @summary))

      assert_selector "[data-testid='histogram-row'][data-rating='4'] [data-testid='histogram-count']", text: "2"
      assert_selector "[data-testid='histogram-row'][data-rating='3'] [data-testid='histogram-count']", text: "0"
    end

    test "labels each row for a screen reader" do
      render_inline(Reviews::HistogramComponent.new(summary: @summary))

      # Scoped to the .sr-only span with exact_text: true so this pins singular vs.
      # plural for real -- a substring match against the row (e.g. text: "1 star")
      # would still pass a broken ternary that always emitted "stars", because
      # "1 stars 0".include?("1 star") is true.
      assert_selector "[data-testid='histogram-row'][data-rating='1'] .sr-only", text: "star", exact_text: true
      assert_selector "[data-testid='histogram-row'][data-rating='5'] .sr-only", text: "stars", exact_text: true
    end

    test "renders nothing without a summary" do
      render_inline(Reviews::HistogramComponent.new(summary: nil))

      assert_no_selector "[data-testid='rating-histogram']"
    end

    test "renders nothing when the summary has no ratings" do
      empty = ReviewSummary.create!(reviewable: books_books(:got))

      render_inline(Reviews::HistogramComponent.new(summary: empty))

      assert_no_selector "[data-testid='rating-histogram']"
    end
  end
end
