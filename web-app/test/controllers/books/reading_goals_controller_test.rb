require "test_helper"

class Books::ReadingGoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @host = Rails.application.config.domains[:books]
    @public_goal = books_reading_goals(:public_goal_other_user)
    @private_goal = books_reading_goals(:private_goal)
    Books::ReadingGoalsController.any_instance.stubs(:default_render) { |controller| controller.head :ok }
  end

  test "anonymous public show is cacheable, viewer-neutral, and has no session cookie" do
    get books_reading_goal_path(@public_goal), headers: {"HOST" => @host}

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "public"
    assert_includes response.headers.fetch("Cache-Control"), "max-age=86400"
    assert_nil response.headers["Set-Cookie"]
    refute_includes response.body, edit_books_my_reading_goal_path(@public_goal)
    refute_includes response.body, "data-signed-in"
  end

  test "private owner and admin show are no-store while strangers receive no-store 404" do
    [@private_goal.user, users(:admin_user), users(:editor_user)].each do |viewer|
      sign_in_as viewer, stub_auth: true
      get books_reading_goal_path(@private_goal), headers: {"HOST" => @host}

      expected = (viewer == @private_goal.user || viewer.admin?) ? :success : :not_found
      assert_response expected
      assert_includes response.headers.fetch("Cache-Control"), "no-store"
    end
  end

  test "canonicalizes query pages and rejects malformed page values" do
    get books_reading_goal_path(@public_goal, page: 1), headers: {"HOST" => @host}
    assert_response :moved_permanently
    assert_redirected_to books_reading_goal_path(@public_goal)

    get books_reading_goal_path(@public_goal, page: 2), headers: {"HOST" => @host}
    assert_response :moved_permanently
    assert_redirected_to books_reading_goal_page_path(@public_goal, 2)

    get books_reading_goal_path(@public_goal, page: "01"), headers: {"HOST" => @host}
    assert_response :not_found
  end

  test "uses twenty-four-item pages and rejects a page past the projection" do
    sign_in_as @private_goal.user, stub_auth: true
    read_list = user_lists(:regular_user_books_read)
    25.times do |index|
      book = Books::Book.create!(title: "Reading goal page #{index}", slug: "reading-goal-page-#{index}")
      read_list.user_list_items.create!(listable: book, completed_on: @private_goal.starts_on)
    end

    get books_reading_goal_page_path(@private_goal, 2), headers: {"HOST" => @host}
    assert_response :success
    assert_equal 2, @controller.view_assigns.fetch("pagy").page
    assert_equal 1, @controller.view_assigns.fetch("progress").items.size

    get books_reading_goal_page_path(@private_goal, 3), headers: {"HOST" => @host}
    assert_response :not_found
  end
end
