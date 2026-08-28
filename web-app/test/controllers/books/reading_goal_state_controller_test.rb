require "test_helper"

class Books::ReadingGoalStateControllerTest < ActionDispatch::IntegrationTest
  test "requires authentication and never allows caching" do
    get "/reading_goal_state/#{books_reading_goals(:public_goal_other_user).id}",
      headers: {"HOST" => Rails.application.config.domains[:books]}, as: :json

    assert_response :unauthorized
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
  end

  test "returns no-store management state for a signed-in owner" do
    goal = books_reading_goals(:private_goal)
    sign_in_as goal.user, stub_auth: true

    get "/reading_goal_state/#{goal.id}", headers: {"HOST" => Rails.application.config.domains[:books]}, as: :json

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_equal true, response.parsed_body.fetch("can_manage")
    assert_equal edit_books_my_reading_goal_path(goal), response.parsed_body.fetch("manage_url")
  end

  test "hides a private goal from a signed-in stranger" do
    sign_in_as users(:editor_user), stub_auth: true

    get "/reading_goal_state/#{books_reading_goals(:private_goal).id}",
      headers: {"HOST" => Rails.application.config.domains[:books]}, as: :json

    assert_response :not_found
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
  end
end
