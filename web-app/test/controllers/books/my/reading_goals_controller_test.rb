require "test_helper"

class Books::My::ReadingGoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @host = Rails.application.config.domains[:books]
    @user = users(:regular_user)
  end

  test "new supplies the required current-year defaults and is no-store" do
    sign_in_as @user, stub_auth: true

    get new_books_my_reading_goal_path, headers: {"HOST" => @host}

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    goal = @controller.view_assigns.fetch("reading_goal")
    assert_equal "My #{Date.current.year} Reading Goal", goal.name
    assert_equal "My yearly reading goal", goal.description
    assert_equal 12, goal.target_count
    assert_equal Date.new(Date.current.year, 1, 1), goal.starts_on
    assert_equal Date.new(Date.current.year, 12, 31), goal.ends_on
    refute goal.public?
  end

  test "index scopes ordinary users to their own goals" do
    sign_in_as @user, stub_auth: true

    get books_my_reading_goals_path, headers: {"HOST" => @host}

    assert_response :success
    goals = @controller.view_assigns.fetch("upcoming_reading_goals")
    assert goals.all? { |goal| goal.user_id == @user.id }
  end

  test "index groups goals in the model scope ordering" do
    sign_in_as @user, stub_auth: true

    get books_my_reading_goals_path, headers: {"HOST" => @host}

    assert_equal [2, 7], @controller.view_assigns.fetch("active_reading_goals").map(&:id)
    assert_equal [3, 8, 5], @controller.view_assigns.fetch("upcoming_reading_goals").map(&:id)
    assert_equal [1, 9, 4], @controller.view_assigns.fetch("finished_reading_goals").map(&:id)
  end

  test "admin index only shows the admin's own goals" do
    sign_in_as users(:admin_user), stub_auth: true

    get books_my_reading_goals_path, headers: {"HOST" => @host}

    groups = %w[active_reading_goals upcoming_reading_goals finished_reading_goals]
    goal_ids = groups.flat_map { |group| @controller.view_assigns.fetch(group).map(&:id) }
    assert_includes goal_ids, books_reading_goals(:public_goal_other_user).id
    refute_includes goal_ids, books_reading_goals(:private_goal).id
  end

  test "anonymous owner route redirects with no-store" do
    get books_my_reading_goals_path, headers: {"HOST" => @host}

    assert_redirected_to "/"
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
  end

  test "validation failure is unprocessable and no-store" do
    sign_in_as @user, stub_auth: true

    post books_my_reading_goals_path, headers: {"HOST" => @host}, params: {
      reading_goal: {name: "", target_count: 0, starts_on: Date.current, ends_on: Date.current, public: false}
    }

    assert_response :unprocessable_entity
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
  end

  test "create, update, and destroy delegate through the goal write services" do
    sign_in_as @user, stub_auth: true

    post books_my_reading_goals_path, headers: {"HOST" => @host}, params: {
      reading_goal: {
        name: "New goal", target_count: 4,
        starts_on: Date.current, ends_on: Date.current + 30.days, public: false
      }
    }
    assert_redirected_to books_my_reading_goals_path
    goal = Books::ReadingGoal.find_by!(name: "New goal")

    patch books_my_reading_goal_path(goal), headers: {"HOST" => @host}, params: {
      reading_goal: {name: "Renamed goal", target_count: 5, starts_on: goal.starts_on, ends_on: goal.ends_on, public: false}
    }
    assert_redirected_to books_my_reading_goals_path
    assert_equal "Renamed goal", goal.reload.name

    delete books_my_reading_goal_path(goal), headers: {"HOST" => @host}
    assert_redirected_to books_my_reading_goals_path
    refute Books::ReadingGoal.exists?(goal.id)
  end

  test "unconfirmed public-to-private purge reports the persisted privacy warning" do
    goal = Books::ReadingGoal.create!(
      user: @user,
      name: "Owner public goal",
      target_count: 12,
      starts_on: Date.current,
      ends_on: Date.current + 1.year,
      public: true
    )
    sign_in_as @user, stub_auth: true
    Services::Books::ReadingGoals::SaveGoal.stubs(:call).returns(
      Services::Books::ReadingGoals::SaveGoal::Result.new(
        success?: false,
        data: {goal: goal, persisted: true, purge_confirmed: false},
        errors: ["Cloudflare purge failed"]
      )
    )

    patch books_my_reading_goal_path(goal), headers: {"HOST" => @host}, params: {
      reading_goal: {name: goal.name, target_count: goal.target_count, starts_on: goal.starts_on, ends_on: goal.ends_on, public: false}
    }

    assert_redirected_to books_my_reading_goals_path
    assert_includes flash[:alert], "edge cache purge confirmation failed"
  end

  test "unauthorized update and destroy are no-store 404s" do
    goal = books_reading_goals(:private_goal)
    sign_in_as users(:editor_user), stub_auth: true

    patch books_my_reading_goal_path(goal), headers: {"HOST" => @host}, params: {
      reading_goal: {name: goal.name, target_count: goal.target_count, starts_on: goal.starts_on, ends_on: goal.ends_on, public: false}
    }
    assert_response :not_found
    assert_includes response.headers.fetch("Cache-Control"), "no-store"

    delete books_my_reading_goal_path(goal), headers: {"HOST" => @host}
    assert_response :not_found
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
  end

  test "admin cannot edit or destroy another user's goal through the personal route" do
    goal = books_reading_goals(:private_goal)
    sign_in_as users(:admin_user), stub_auth: true

    get edit_books_my_reading_goal_path(goal), headers: {"HOST" => @host}
    assert_response :not_found
    assert_includes response.headers.fetch("Cache-Control"), "no-store"

    delete books_my_reading_goal_path(goal), headers: {"HOST" => @host}
    assert_response :not_found
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
  end
end
