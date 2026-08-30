# frozen_string_literal: true

require "test_helper"

class Books::ReadingGoals::ProgressComponentTest < ViewComponent::TestCase
  test "renders truthful over-target text with a capped native progress element" do
    render_inline Books::ReadingGoals::ProgressComponent.new(
      count: 15,
      target_count: 12,
      percentage: 125.0,
      bar_percentage: 100.0
    )

    assert_text "15 of 12 books"
    assert_text "125%"
    assert_selector "progress[value='100'][max='100'][aria-label='15 of 12 books, 125% complete']"
  end

  test "preserves a meaningful fractional percentage" do
    render_inline Books::ReadingGoals::ProgressComponent.new(
      count: 1,
      target_count: 3,
      percentage: 33.3,
      bar_percentage: 33.3
    )

    assert_text "33.3%"
    assert_selector "progress[value='33.3']"
  end
end
