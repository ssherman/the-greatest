# frozen_string_literal: true

require "test_helper"

module Reviews
  class CardComponentTest < ViewComponent::TestCase
    setup do
      @book = books_books(:war_and_peace)
      @summary = review_summaries(:war_and_peace)
      @reviews = @book.reviews.with_body.recent
    end

    test "anchors at the id the summary line links to" do
      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))

      assert_selector "#ratings-reviews"
    end

    test "mounts the spoiler controller on the card, not on the spans" do
      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))

      assert_selector "#ratings-reviews[data-controller='reviews--spoiler']"
      assert_selector "#ratings-reviews[data-action*='click->reviews--spoiler#reveal']"
      assert_selector "#ratings-reviews[data-action*='keydown->reviews--spoiler#revealOnKey']"
    end

    test "renders the histogram" do
      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))

      assert_selector "[data-testid='rating-histogram']"
    end

    test "renders one block per written review" do
      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))

      assert_selector "[data-testid='review']", count: 2
    end

    test "loads an unloaded reviews relation exactly once" do
      # @reviews is `book.reviews.with_body.recent`, still unloaded here. A naive
      # `reviews.any?` followed by `reviews.each` would issue a SELECT ... LIMIT for
      # the emptiness check and then a second, full SELECT for the loop -- two queries
      # against the same relation. Pinned at 1 so that regresses loudly.
      assert_queries_count(1) do
        render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))
      end
    end

    test "the anchor target is focusable so keyboard/screen-reader arrival is announced" do
      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))

      assert_selector "#ratings-reviews[tabindex='-1']"
    end

    test "renders the reviews in the order it was given them" do
      # An explicit array, not the scope: both fixture reviews share a created_at, so
      # asserting that a sorted list is sorted would pass without proving anything.
      ordered = [reviews(:editor_user_war_and_peace), reviews(:regular_user_war_and_peace)]

      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: ordered))

      bodies = page.all("[data-testid='review-body']").map(&:text)
      assert_match(/Skip the philosophy/, bodies.first)
      assert_match(/Worth every one/, bodies.last)
    end

    test "says so when a book is rated but nobody has written anything" do
      render_inline(Reviews::CardComponent.new(
        summary: review_summaries(:crime_and_punishment),
        reviews: Review.none
      ))

      assert_selector "#ratings-reviews"
      assert_text "No written reviews yet"
      assert_no_selector "[data-testid='review']"
    end

    test "prints the average and the rating count in the header" do
      render_inline(Reviews::CardComponent.new(summary: @summary, reviews: @reviews))

      assert_text "4.3"
      # Word-boundary regex, not a plain substring: "3 ratings" is itself a substring
      # of a corrupted "13 ratings" -- see SummaryLineComponentTest, which caught this
      # exact shape of vacuous assertion against the same fixture.
      assert_text(/\b3 ratings\b/)
    end

    test "renders nothing at all for a book with no ratings" do
      empty = ReviewSummary.create!(reviewable: books_books(:got))

      render_inline(Reviews::CardComponent.new(summary: empty, reviews: Review.none))

      assert_no_selector "#ratings-reviews"
    end

    test "renders nothing without a summary" do
      render_inline(Reviews::CardComponent.new(summary: nil, reviews: Review.none))

      assert_no_selector "#ratings-reviews"
    end
  end
end
