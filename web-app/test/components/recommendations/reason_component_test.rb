# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ReasonComponentTest < ViewComponent::TestCase
    def reason(type, ids)
      Recommendations::Reason.new(type: type, ids: ids)
    end

    test "interests name the two categories" do
      render_inline(ReasonComponent.new(reason: reason(:interests, [1, 2]), names: {[:category, 1] => "Dark", [:category, 2] => "Guilt"}))
      assert_selector "[data-testid='recommendation-reason']", text: "Matches Dark and Guilt"
    end

    test "because_of names the book" do
      render_inline(ReasonComponent.new(reason: reason(:because_of, [9]), names: {[:item, 9] => "Molloy"}))
      assert_text "Because you loved Molloy"
    end

    test "a category id and a book id that are the same integer each show their own name" do
      names = {[:category, 5] => "Dark", [:item, 5] => "Molloy"}
      render_inline(ReasonComponent.new(reason: reason(:interests, [5]), names: names))
      assert_text "Matches Dark"
      render_inline(ReasonComponent.new(reason: reason(:because_of, [5]), names: names))
      assert_text "Because you loved Molloy"
    end

    test "ranked states the position" do
      render_inline(ReasonComponent.new(reason: reason(:ranked, [37]), names: {}))
      assert_text "Ranked #37 of all time"
    end

    test "a missing name falls back to the id instead of raising" do
      render_inline(ReasonComponent.new(reason: reason(:interests, [1, 404]), names: {[:category, 1] => "Dark"}))
      assert_text "Matches Dark and #404"
    end

    test "a ranked reason with no position still renders" do
      render_inline(ReasonComponent.new(reason: reason(:ranked, []), names: {}))
      assert_text "On the all-time list"
    end
  end
end
