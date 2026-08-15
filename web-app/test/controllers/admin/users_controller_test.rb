require "test_helper"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @regular_user = users(:regular_user)

    host! Rails.application.config.domains[:music]
    sign_in_as(@admin, stub_auth: true)
  end

  test "should get index" do
    get admin_users_url
    assert_response :success
  end

  test "should get index with search query" do
    get admin_users_url(q: "admin")
    assert_response :success
  end

  test "should filter users by email on search" do
    get admin_users_url(q: "admin@example.com")
    assert_response :success
  end

  test "should handle empty search results without error" do
    get admin_users_url(q: "nonexistentemail@nowhere.com")
    assert_response :success
  end

  test "should get show" do
    get admin_user_url(@regular_user)
    assert_response :success
  end

  test "should get edit" do
    get edit_admin_user_url(@regular_user)
    assert_response :success
  end

  test "should update user with valid data" do
    patch admin_user_url(@regular_user), params: {
      user: {
        display_name: "Updated Display Name"
      }
    }
    assert_redirected_to admin_user_url(@regular_user)
    @regular_user.reload
    assert_equal "Updated Display Name", @regular_user.display_name
  end

  test "should update user role" do
    patch admin_user_url(@regular_user), params: {
      user: {
        role: "editor"
      }
    }
    assert_redirected_to admin_user_url(@regular_user)
    @regular_user.reload
    assert_equal "editor", @regular_user.role
  end

  test "should not update user with invalid data" do
    patch admin_user_url(@regular_user), params: {
      user: {
        email: ""
      }
    }
    assert_response :unprocessable_entity
  end

  test "should not update user with duplicate email" do
    patch admin_user_url(@regular_user), params: {
      user: {
        email: @admin.email
      }
    }
    assert_response :unprocessable_entity
  end

  test "should destroy user" do
    user_to_delete = User.create!(
      email: "todelete@example.com",
      role: :user,
      email_verified: false
    )

    assert_difference("User.count", -1) do
      delete admin_user_url(user_to_delete)
    end
    assert_redirected_to admin_users_url
  end

  test "should destroy user with submitted external links" do
    user_to_delete = User.create!(
      email: "linksubmitter@example.com",
      role: :user,
      email_verified: false
    )

    # Create an external link submitted by this user
    external_link = ExternalLink.create!(
      name: "Test Link",
      url: "https://example.com",
      parent: music_artists(:the_beatles),
      submitted_by_id: user_to_delete.id
    )

    assert_difference("User.count", -1) do
      delete admin_user_url(user_to_delete)
    end
    assert_redirected_to admin_users_url

    # Verify the external link still exists but submitted_by_id is nullified
    external_link.reload
    assert_nil external_link.submitted_by_id
  end

  test "should destroy user with a saved search" do
    user_to_delete = User.create!(
      email: "searchowner@example.com",
      role: :user,
      email_verified: false
    )

    saved_search = Books::SavedSearch.create!(user: user_to_delete, criteria: {"genre_match_mode" => "any"})

    assert_difference("User.count", -1) do
      delete admin_user_url(user_to_delete)
    end
    assert_redirected_to admin_users_url

    # Verify the saved search was destroyed along with the user (dependent: :destroy)
    # rather than raising ActiveRecord::InvalidForeignKey.
    assert_nil SavedSearch.find_by(id: saved_search.id)
  end

  test "should allow admin access" do
    get admin_users_url
    assert_response :success
  end

  test "should deny editor access" do
    sign_in_as(@editor, stub_auth: true)
    get admin_users_url
    assert_redirected_to music_root_url
  end

  test "should deny regular user access" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_users_url
    assert_redirected_to music_root_url
  end

  test "should deny unauthenticated access" do
    # Reset session to simulate unauthenticated user
    reset!
    host! Rails.application.config.domains[:music]
    get admin_users_url
    assert_redirected_to music_root_url
  end

  test "renders the games layout when browsing from the games host" do
    host! Rails.application.config.domains[:games]
    sign_in_as(@admin, stub_auth: true)

    get admin_users_path

    assert_response :success
    assert_select "aside[data-testid=admin-sidebar]"
    assert_select "title", text: /The Greatest Games/
    assert_match %r{/assets/games-[^"]*\.css}, response.body
    assert_no_match %r{/assets/music-[^"]*\.css}, response.body
  end

  test "renders the music layout when browsing from the music host" do
    host! Rails.application.config.domains[:music]
    sign_in_as(@admin, stub_auth: true)

    get admin_users_path

    assert_response :success
    assert_select "aside[data-testid=admin-sidebar]"
    assert_select "title", text: /The Greatest Music/
    assert_match %r{/assets/music-[^"]*\.css}, response.body
    assert_no_match %r{/assets/games-[^"]*\.css}, response.body
  end

  test "show renders for a user with reviews" do
    assert_operator @regular_user.reviews.count, :>, 0
    get admin_user_url(@regular_user)
    assert_response :success
  end

  test "show renders for a user with no reviews" do
    user = users(:editor_user)
    user.reviews.destroy_all
    get admin_user_url(user)
    assert_response :success
  end

  # The setup block puts this request on the MUSIC host, which is exactly the
  # case a path-only link breaks in: /admin/reviews routes on the books host
  # only. Asserts on the generated URL, not on markup -- this is a routing
  # decision, not presentation, and it is invisible in development where every
  # host resolves to localhost.
  test "review links on the user page carry the books host" do
    get admin_user_url(@regular_user)
    assert_response :success
    assert_includes response.body, Rails.application.config.domains[:books]
  end

  # Not a fixed query count -- that would break every time an unrelated panel is
  # added to this page. Instead: adding four more reviews must not add any
  # queries. Drop includes(:reviewable) from the controller and this fails by
  # exactly four.
  test "the reviews card does not issue a query per review" do
    baseline = sql_query_count { get admin_user_url(@regular_user) }

    [:combo_steinbeck, :got, :clash, :of_mice_and_men].each do |slug|
      @regular_user.reviews.create!(reviewable: books_books(slug), rating: 3)
    end

    grown = sql_query_count { get admin_user_url(@regular_user) }

    assert_equal baseline, grown,
      "the reviews card N+1s: 4 extra reviews cost #{grown - baseline} extra queries"
  end

  private

  def sql_query_count
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      count += 1 unless payload[:name].in?(["SCHEMA", "TRANSACTION"])
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
