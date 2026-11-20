require "test_helper"

class Books::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @host = Rails.application.config.domains[:books]
    @user = users(:profile_reader)
    @profile = books_profiles(:public_profile)
    Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
  end

  test "a public profile renders signed out with edge-only cache headers" do
    get books_profile_path(@profile), headers: {"HOST" => @host}

    assert_response :success
    cache_control = response.headers.fetch("Cache-Control")
    assert_includes cache_control, "s-maxage=600"
    assert_includes cache_control, "max-age=0"
    assert_includes cache_control, "public"
    assert_nil response.headers["Set-Cookie"]
    assert_equal :public, @controller.view_assigns.fetch("profile_data").audience
  end

  test "a private profile is 404 and no-store for a visitor, the owner and an admin" do
    private_profile = books_profiles(:private_profile)

    get books_profile_path(private_profile), headers: {"HOST" => @host}
    assert_response :not_found
    assert_includes response.headers.fetch("Cache-Control"), "no-store"

    [users(:profile_empty_reader), users(:admin_user)].each do |viewer|
      sign_in_as viewer, stub_auth: true

      get books_profile_path(private_profile), headers: {"HOST" => @host}

      assert_response :not_found
      assert_includes response.headers.fetch("Cache-Control"), "no-store"
    end
  end

  test "an unknown id is 404" do
    get books_profile_path(id: 0), headers: {"HOST" => @host}

    assert_response :not_found
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
  end

  test "the response is the same signed in and signed out, for the owner too" do
    favorite(books_books(:war_and_peace))

    get books_profile_path(@profile), headers: {"HOST" => @host}
    signed_out = response.body

    sign_in_as @user, stub_auth: true
    get books_profile_path(@profile), headers: {"HOST" => @host}

    assert_response :success
    assert_equal signed_out, response.body
    assert_nil response.headers["Set-Cookie"]
  end

  test "a switched-off section's data is not in the response" do
    favorite(books_books(:war_and_peace))
    get books_profile_path(@profile), headers: {"HOST" => @host}
    assert_includes response.body, "War and Peace"

    @profile.update!(show_favorites: false)
    get books_profile_path(@profile), headers: {"HOST" => @host}

    assert_response :success
    assert_not_includes response.body, "War and Peace"
  end

  test "a provisional book is not in the response" do
    book = books_books(:war_and_peace)
    favorite(book)
    book.update_column(:provisional, true)

    get books_profile_path(@profile), headers: {"HOST" => @host}

    assert_response :success
    assert_not_includes response.body, "War and Peace"
  end

  test "a private list is not linked from the public shelf, a public one is" do
    list = favorite(books_books(:war_and_peace))

    get books_profile_path(@profile), headers: {"HOST" => @host}
    assert_not_includes response.body, user_list_path(list)

    list.update_column(:public, true)
    get books_profile_path(@profile), headers: {"HOST" => @host}
    assert_includes response.body, user_list_path(list)
    assert_not_includes response.body, my_list_path(list)
  end

  test "the display name is escaped" do
    @profile.update_column(:display_name, "<b>Al</b>")

    get books_profile_path(@profile), headers: {"HOST" => @host}

    assert_response :success
    assert_includes response.body, "&lt;b&gt;Al&lt;/b&gt;"
    assert_not_includes response.body, "<b>Al</b>"
  end

  test "the page carries noindex" do
    get books_profile_path(@profile), headers: {"HOST" => @host}

    assert_select "meta[name=robots][content*=noindex]"
  end

  test "private -> public makes the URL work again" do
    @profile.update!(public: false)
    get books_profile_path(@profile), headers: {"HOST" => @host}
    assert_response :not_found

    @profile.update!(public: true)
    get books_profile_path(@profile), headers: {"HOST" => @host}

    assert_response :success
  end

  test "an owner-only shelf prompt is not shown to visitors" do
    get books_profile_path(@profile), headers: {"HOST" => @host}

    assert_response :success
    assert_select "[data-testid=profile-favorites-prompt]", count: 0
    assert_select "[data-testid=profile-sharing]", count: 0
  end

  test "the public page has no frame-trapped links" do
    favorite(books_books(:war_and_peace))

    host! @host
    assert_no_frame_trapped_links books_profile_path(@profile)
  end

  test "the own page has no frame-trapped links" do
    host! @host
    sign_in_as @user, stub_auth: true

    assert_no_frame_trapped_links books_my_profile_path
  end

  test "is not routable on the music host" do
    get "/profiles/#{@profile.id}", headers: {"HOST" => Rails.application.config.domains[:music]}

    assert_response :not_found
  end

  private

  def favorite(book)
    list = Books::UserList.create!(user: @user, list_type: :favorites,
      name: Books::UserList.default_list_name_for(:favorites))
    list.user_list_items.create!(listable: book)
    list
  end
end
