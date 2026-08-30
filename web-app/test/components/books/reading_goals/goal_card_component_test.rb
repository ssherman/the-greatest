# frozen_string_literal: true

require "test_helper"

class Books::ReadingGoals::GoalCardComponentTest < ViewComponent::TestCase
  setup do
    @progress = Services::Books::ReadingGoals::ProgressQuery::Progress.new(
      items: [], count: 2, percentage: 33.3, complete: false, bar_percentage: 33.3
    )
  end

  test "renders a private goal summary and its management actions" do
    goal = books_reading_goals(:active_ending_soon)
    routes = Rails.application.routes.url_helpers

    render_inline Books::ReadingGoals::GoalCardComponent.new(goal: goal, progress: @progress)

    assert_text "Finish Summer Reading"
    assert_text "August 1, 2026 – August 26, 2026"
    assert_selector ".badge", text: "Private"
    assert_text "2 of 5 books"
    assert_text "33.3%"
    assert_link "View", href: routes.books_reading_goal_path(goal)
    assert_link "Edit", href: routes.edit_books_my_reading_goal_path(goal)
    assert_selector "form[action='#{routes.books_my_reading_goal_path(goal)}'][data-turbo-confirm] button", text: "Delete"
    assert_no_text "Copy Share Link"
    assert_no_selector "[data-controller='clipboard-copy']"
  end

  test "offers a readonly share source only for public goals" do
    goal = books_reading_goals(:public_goal_other_user)
    share_path = Rails.application.routes.url_helpers.books_reading_goal_path(goal)

    render_inline Books::ReadingGoals::GoalCardComponent.new(goal: goal, progress: @progress)

    assert_selector ".badge", text: "Public"
    assert_selector "[data-controller='clipboard-copy']" do
      assert_selector "input[readonly][data-clipboard-copy-target='source'][value$='#{share_path}']"
      assert_selector "button[data-action='clipboard-copy#copy'][data-clipboard-copy-target='button']",
        text: "Copy Share Link"
    end
  end

  test "keeps the hidden share source out of sequential focus order" do
    goal = books_reading_goals(:public_goal_other_user)

    render_inline Books::ReadingGoals::GoalCardComponent.new(goal: goal, progress: @progress)

    assert_selector "input[readonly][tabindex='-1'][data-clipboard-copy-target='source']"
  end

  test "copy button starts with the shared feedback controller class" do
    goal = books_reading_goals(:public_goal_other_user)

    render_inline Books::ReadingGoals::GoalCardComponent.new(goal: goal, progress: @progress)

    assert_selector "button.btn-primary[data-action='clipboard-copy#copy'][data-clipboard-copy-target='button']"
  end
end
