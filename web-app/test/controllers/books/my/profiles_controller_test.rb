require "test_helper"

class Books::My::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @host = Rails.application.config.domains[:books]
    Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
  end

  test "signed out is sent through the usual sign-in handling" do
    get books_my_profile_path, headers: {"HOST" => @host}

    assert_redirected_to "/"
  end

  test "renders for a reader with data and is no-store" do
    user = users(:profile_reader)
    list = Books::UserList.create!(user: user, list_type: :favorites,
      name: Books::UserList.default_list_name_for(:favorites))
    list.user_list_items.create!(listable: books_books(:war_and_peace))
    Review.create!(user: user, reviewable: books_books(:war_and_peace), rating: 4.25, body: "Enormous and worth it.")
    sign_in_as user, stub_auth: true

    get books_my_profile_path, headers: {"HOST" => @host}

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_equal :owner, @controller.view_assigns.fetch("profile_data").audience
  end

  test "renders for an empty account" do
    sign_in_as users(:profile_empty_reader), stub_auth: true

    get books_my_profile_path, headers: {"HOST" => @host}

    assert_response :success
  end

  test "renders when the recommendation engine raises" do
    Recommendations::Books::Pages.any_instance.stubs(:history?).returns(true)
    Recommendations::Engine.stubs(:call).raises(RuntimeError, "boom")
    sign_in_as users(:profile_reader), stub_auth: true

    get books_my_profile_path, headers: {"HOST" => @host}

    assert_response :success
  end

  test "own page shows the privacy status and a link to the settings" do
    sign_in_as users(:profile_reader), stub_auth: true

    get books_my_profile_path, headers: {"HOST" => @host}

    assert_select "[data-testid=profile-status]", text: "Public"
    assert_select "a[href=?]", books_my_profile_settings_path
  end

  test "own page shows Private for an account with no profile" do
    sign_in_as users(:regular_user), stub_auth: true

    get books_my_profile_path, headers: {"HOST" => @host}

    assert_select "[data-testid=profile-sharing]", count: 0
  end

  test "settings GET does not create a profile row" do
    sign_in_as users(:regular_user), stub_auth: true

    assert_no_difference "Books::Profile.count" do
      get books_my_profile_settings_path, headers: {"HOST" => @host}
    end

    assert_response :success
  end

  test "settings prefill the display name from the account for a new profile" do
    user = users(:regular_user)
    sign_in_as user, stub_auth: true

    get books_my_profile_settings_path, headers: {"HOST" => @host}

    assert_select "input[name='books_profile[display_name]'][value=?]", user.display_name
  end

  test "settings show the public link only once public" do
    sign_in_as users(:profile_reader), stub_auth: true
    get books_my_profile_settings_path, headers: {"HOST" => @host}
    assert_select "[data-testid=profile-public-url][readonly]"

    sign_in_as users(:profile_empty_reader), stub_auth: true
    get books_my_profile_settings_path, headers: {"HOST" => @host}
    assert_select "[data-testid=profile-public-url]", count: 0
  end

  test "update creates the profile and redirects" do
    sign_in_as users(:regular_user), stub_auth: true

    assert_difference "Books::Profile.count", 1 do
      patch books_my_profile_settings_path, headers: {"HOST" => @host},
        params: {books_profile: {public: "1", display_name: "Reader One", show_stats: "1"}}
    end

    assert_redirected_to books_my_profile_settings_path
    assert_equal "Profile settings saved.", flash[:notice]
    profile = users(:regular_user).reload.books_profile
    assert_equal ["Reader One", true, true, false], [profile.display_name, profile.public?, profile.show_stats, profile.show_reviews]
  end

  test "update with public on and a blank display name re-renders 422 and saves nothing" do
    sign_in_as users(:regular_user), stub_auth: true

    assert_no_difference "Books::Profile.count" do
      patch books_my_profile_settings_path, headers: {"HOST" => @host},
        params: {books_profile: {public: "1", display_name: ""}}
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid=profile-settings-errors]"
  end

  test "update that hides a section calls the synchronous purge" do
    purge = mock("purge")
    purge.stubs(:purge_urls).returns(success: true)
    Cloudflare::PurgeService.stubs(:new).returns(purge)
    sign_in_as users(:profile_reader), stub_auth: true

    with_env("CLOUDFLARE_CACHE_PURGE_TOKEN" => "test-token") do
      patch books_my_profile_settings_path, headers: {"HOST" => @host},
        params: {books_profile: {public: "1", display_name: "Avid Reader", show_reviews: "0"}}
    end

    assert_redirected_to books_my_profile_settings_path
    assert_equal "Profile settings saved.", flash[:notice]
    assert_not books_profiles(:public_profile).reload.show_reviews
  end

  test "update reports an unconfirmed purge with an alert and still saves" do
    purge = mock("purge")
    purge.stubs(:purge_urls).returns(success: false, error: "boom")
    Cloudflare::PurgeService.stubs(:new).returns(purge)
    host! @host
    sign_in_as users(:profile_reader), stub_auth: true

    with_env("CLOUDFLARE_CACHE_PURGE_TOKEN" => "test-token") do
      patch books_my_profile_settings_path, headers: {"HOST" => @host},
        params: {books_profile: {public: "0", display_name: "Avid Reader"}}
    end

    assert_redirected_to books_my_profile_settings_path
    assert_includes flash[:alert], "could not confirm the cached copy was cleared"
    assert_not books_profiles(:public_profile).reload.public?
    follow_redirect!
    assert_select "[data-testid=profile-settings-alert]"
  end

  test "update ignores parameters outside the permitted list" do
    other = users(:regular_user)
    sign_in_as users(:profile_reader), stub_auth: true

    patch books_my_profile_settings_path, headers: {"HOST" => @host},
      params: {books_profile: {display_name: "Avid Reader", user_id: other.id, id: 0}}

    assert_equal users(:profile_reader).id, books_profiles(:public_profile).reload.user_id
    assert_nil other.reload.books_profile
  end

  test "preview renders the public audience uncached for a private profile" do
    sign_in_as users(:profile_empty_reader), stub_auth: true

    get books_my_profile_preview_path, headers: {"HOST" => @host}

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_equal :public, @controller.view_assigns.fetch("profile_data").audience
  end

  test "preview without a profile redirects to settings" do
    sign_in_as users(:regular_user), stub_auth: true

    get books_my_profile_preview_path, headers: {"HOST" => @host}

    assert_redirected_to books_my_profile_settings_path
  end

  test "all three actions require sign-in" do
    get books_my_profile_settings_path, headers: {"HOST" => @host}
    assert_redirected_to "/"

    patch books_my_profile_settings_path, headers: {"HOST" => @host}, params: {books_profile: {public: "1"}}
    assert_redirected_to "/"

    get books_my_profile_preview_path, headers: {"HOST" => @host}
    assert_redirected_to "/"
  end

  test "is not routable on the music host" do
    sign_in_as users(:profile_reader), stub_auth: true

    get "/my/profile", headers: {"HOST" => Rails.application.config.domains[:music]}

    assert_response :not_found
  end
end
