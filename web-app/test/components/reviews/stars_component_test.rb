# frozen_string_literal: true

require "test_helper"

module Reviews
  class StarsComponentTest < ViewComponent::TestCase
    test "clips the fill layer to the rating as a percentage of five" do
      render_inline(Reviews::StarsComponent.new(rating: 4))

      assert_selector "[data-testid='stars-fill'][style*='width: 80.0%']"
    end

    test "clips a fractional average proportionally rather than rounding it" do
      render_inline(Reviews::StarsComponent.new(rating: 3.96))

      assert_selector "[data-testid='stars-fill'][style*='width: 79.2%']"
    end

    test "renders five stars in each of the two layers" do
      render_inline(Reviews::StarsComponent.new(rating: 5))

      assert_selector "[data-testid='stars-track'] svg", count: 5
      assert_selector "[data-testid='stars-fill'] svg", count: 5
    end

    test "fills the overlay stars and leaves the track stars outlined" do
      render_inline(Reviews::StarsComponent.new(rating: 5))

      assert_selector "[data-testid='stars-fill'] svg.fill-current", count: 5
      assert_no_selector "[data-testid='stars-track'] svg.fill-current"
    end

    test "exposes a single accessible label and hides the decorative layers" do
      render_inline(Reviews::StarsComponent.new(rating: 4.25))

      assert_selector "[role='img'][aria-label='4.3 out of 5 stars']"
      assert_selector "[data-testid='stars-track'][aria-hidden='true']"
      assert_selector "[data-testid='stars-fill'][aria-hidden='true']"
    end

    test "accepts a caller-supplied label" do
      render_inline(Reviews::StarsComponent.new(rating: 3.96, label: "Average rating 4.0 out of 5"))

      assert_selector "[role='img'][aria-label='Average rating 4.0 out of 5']"
    end

    test "renders an empty track for a nil rating" do
      render_inline(Reviews::StarsComponent.new(rating: nil))

      assert_selector "[data-testid='stars-fill'][style*='width: 0.0%']"
      assert_selector "[role='img'][aria-label='Not yet rated']"
    end

    test "clamps a rating outside one to five" do
      render_inline(Reviews::StarsComponent.new(rating: 9))

      assert_selector "[data-testid='stars-fill'][style*='width: 100.0%']"
    end

    test "applies a caller-supplied size class to every star" do
      render_inline(Reviews::StarsComponent.new(rating: 2, size: "size-3"))

      assert_selector "svg.size-3", count: 10
      assert_no_selector "svg.size-4"
    end
  end
end
