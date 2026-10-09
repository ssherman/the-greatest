# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ProgressComponentTest < ViewComponent::TestCase
    test "marks the current and earlier steps and links every step when unlocked" do
      render_inline(ProgressComponent.new(current_step: 2, unlocked: true))
      assert_selector "li.step.step-primary", count: 2
      assert_selector "li.step", count: 4
      assert_selector "a[href='/recommendations/wizard/4']"
    end

    test "steps 3 and 4 are not links while the user has no history" do
      render_inline(ProgressComponent.new(current_step: 1, unlocked: false))
      assert_selector "a[href='/recommendations/wizard/2']"
      assert_no_selector "a[href='/recommendations/wizard/3']"
      assert_no_selector "a[href='/recommendations/wizard/4']"
      assert_text "Ratings"
    end
  end
end
