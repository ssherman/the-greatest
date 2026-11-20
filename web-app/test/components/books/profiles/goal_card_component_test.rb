# frozen_string_literal: true

require "test_helper"

class Books::Profiles::GoalCardComponentTest < ViewComponent::TestCase
  def progress(count: 3, target: 12)
    goal = Books::ReadingGoal.new(user: users(:profile_reader), name: "Twelve in <b>2026</b>", target_count: target,
      starts_on: Date.current.beginning_of_year, ends_on: Date.current.end_of_year)
    Services::Books::Profiles::Library::GoalProgress.new(goal: goal, count: count, bar_percentage: 25.0, days_left: 40)
  end

  test "renders each goal's progress and escapes its name" do
    render_inline Books::Profiles::GoalCardComponent.new(goals: [progress], reading_now: nil, audience: :owner)

    assert_selector "[data-testid='profile-goal'] progress[value='25']"
    assert_text "3 of 12 books"
    assert_text "40 days left"
    assert_text "Twelve in <b>2026</b>"
  end

  test "owner with nothing gets the prompt card; public gets nothing" do
    render_inline Books::Profiles::GoalCardComponent.new(goals: [], reading_now: nil, audience: :owner)
    assert_selector "[data-testid='profile-goals-prompt'].card-dash a", count: 1

    refute Books::Profiles::GoalCardComponent.new(goals: [], reading_now: nil, audience: :public).render?
    refute Books::Profiles::GoalCardComponent.new(goals: nil, reading_now: nil, audience: :public).render?
  end

  test "reading now appears under the goal and is omitted when empty" do
    shelf = Services::Books::Profiles::Library::Shelf.new(books: [books_books(:war_and_peace)], total: 1, list: nil)

    render_inline Books::Profiles::GoalCardComponent.new(goals: [progress], reading_now: shelf, audience: :public)
    assert_selector "[data-testid='profile-reading-now'] [data-testid='profile-book']"

    render_inline Books::Profiles::GoalCardComponent.new(goals: [progress], reading_now: nil, audience: :public)
    assert_no_selector "[data-testid='profile-reading-now']"
  end

  test "public sees reading now even without a goal, with no prompt" do
    shelf = Services::Books::Profiles::Library::Shelf.new(books: [books_books(:war_and_peace)], total: 1, list: nil)

    render_inline Books::Profiles::GoalCardComponent.new(goals: [], reading_now: shelf, audience: :public)

    assert_selector "[data-testid='profile-reading-now']"
    assert_no_link "Set a reading goal"
  end

  test "public links a goal only when the page may link to it" do
    item = progress
    item.goal.id = 5

    render_inline Books::Profiles::GoalCardComponent.new(goals: [item], reading_now: nil, audience: :public, data: stub(linkable?: true))
    assert_link "Twelve in <b>2026</b>", href: "/reading_goals/5"

    render_inline Books::Profiles::GoalCardComponent.new(goals: [item], reading_now: nil, audience: :public, data: stub(linkable?: false))
    assert_no_link "Twelve in <b>2026</b>"

    render_inline Books::Profiles::GoalCardComponent.new(goals: [item], reading_now: nil, audience: :public)
    assert_no_link "Twelve in <b>2026</b>"
  end
end
