require "test_helper"

class Books::My::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @host = Rails.application.config.domains[:books]
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

  test "is not routable on the music host" do
    sign_in_as users(:profile_reader), stub_auth: true

    get "/my/profile", headers: {"HOST" => Rails.application.config.domains[:music]}

    assert_response :not_found
  end
end
