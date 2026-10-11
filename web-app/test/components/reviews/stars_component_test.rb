# frozen_string_literal: true

require "test_helper"

module Reviews
  class StarsComponentTest < ViewComponent::TestCase
    def fills
      page.all("[data-testid='star-fill']", visible: :all).map { |el| el[:style] }
    end

    test "fills each star separately: 3.75 is three full, three quarters, empty" do
      render_inline(Reviews::StarsComponent.new(rating: BigDecimal("3.75")))

      assert_equal ["width: 100.0%", "width: 100.0%", "width: 100.0%", "width: 75.0%", "width: 0.0%"], fills
    end

    test "a fractional average fills its partial star proportionally" do
      render_inline(Reviews::StarsComponent.new(rating: 3.96))

      assert_equal "width: 96.0%", fills[3]
      assert_equal "width: 0.0%", fills[4]
    end

    test "renders a track and a filled star for each of five stars" do
      render_inline(Reviews::StarsComponent.new(rating: 5))

      assert_selector "[data-testid='star']", count: 5
      assert_selector "[data-testid='star-track'] svg", count: 5
      assert_selector "[data-testid='star-fill'] svg.fill-current", count: 5
      assert_no_selector "[data-testid='star-track'] svg.fill-current"
    end

    test "an average label keeps one decimal" do
      render_inline(Reviews::StarsComponent.new(rating: 4.25))

      assert_selector "[role='img'][aria-label='4.3 out of 5 stars']"
      assert_selector "[data-testid='star'][aria-hidden='true']", count: 5
    end

    test "an exact label reads a single rating as entered" do
      render_inline(Reviews::StarsComponent.new(rating: BigDecimal("3.75"), exact: true))

      assert_selector "[role='img'][aria-label='3.75 out of 5 stars']"
    end

    test "accepts a caller-supplied label" do
      render_inline(Reviews::StarsComponent.new(rating: 3.96, label: "Average rating 4.0 out of 5"))

      assert_selector "[role='img'][aria-label='Average rating 4.0 out of 5']"
    end

    test "a nil rating renders empty stars and says so" do
      render_inline(Reviews::StarsComponent.new(rating: nil))

      assert_equal ["width: 0.0%"] * 5, fills
      assert_selector "[role='img'][aria-label='Not yet rated']"
    end

    test "clamps a rating above five, and the label matches the fill" do
      render_inline(Reviews::StarsComponent.new(rating: 9))

      assert_equal ["width: 100.0%"] * 5, fills
      assert_selector "[role='img'][aria-label='5.0 out of 5 stars']"
    end

    test "applies a caller-supplied size class to every star" do
      render_inline(Reviews::StarsComponent.new(rating: 2, size: "size-3"))

      assert_selector "svg.size-3", count: 10
      assert_no_selector "svg.size-4"
    end
  end
end
