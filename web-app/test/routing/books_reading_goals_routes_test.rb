require "test_helper"

class BooksReadingGoalsRoutesTest < ActionDispatch::IntegrationTest
  HOST = Rails.application.config.domains[:books]

  test "books reading-goal routes resolve only on the books host" do
    assert_routing({method: :get, path: "http://#{HOST}/reading_goals/123"},
      controller: "books/reading_goals", action: "show", id: "123")
    assert_routing({method: :get, path: "http://#{HOST}/my/reading-goals"},
      controller: "books/my/reading_goals", action: "index")
    assert_routing({method: :get, path: "http://#{HOST}/reading_goal_state/123"},
      controller: "books/reading_goal_state", action: "show", id: "123")
    assert_routing({method: :get, path: "http://#{HOST}/reading_goals/123/page/2"},
      controller: "books/reading_goals", action: "show", id: "123", page: "2")
  end

  test "legacy reading-goal routes are permanent redirects" do
    host! HOST

    get "/reading_goals"
    assert_response :moved_permanently
    assert_redirected_to "/my/reading-goals"

    get "/reading_goals/new"
    assert_response :moved_permanently
    assert_redirected_to "/my/reading-goals/new"

    get "/reading_goals/123/edit"
    assert_response :moved_permanently
    assert_redirected_to "/my/reading-goals/123/edit"
  end
end
