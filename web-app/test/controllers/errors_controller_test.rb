require "test_helper"

class ErrorsControllerTest < ActionDispatch::IntegrationTest
  # Each site's layout, keyed by the theme it stamps on <html> -- the same
  # signal pages_controller_test uses to prove DomainLayout resolved.
  SITES = {
    books: "books",
    music: "light",
    games: "abyss"
  }.freeze

  # Test runs with consider_all_requests_local, which answers an unmatched route
  # with Rails' debug page instead of the exceptions_app. Production's setting,
  # for these tests only.
  setup do
    @detailed_exceptions = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
  end

  teardown do
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed_exceptions
  end

  def host_for(domain)
    Rails.application.config.domains[domain].to_s.split(",").first
  end

  SITES.each do |domain, theme|
    test "an unknown path is a 404 in the #{domain} layout on the #{domain} host" do
      host! host_for(domain)

      get "/no-such-page-anywhere"

      assert_response :not_found
      assert_select "html[data-theme=#{theme}]"
      assert_select "meta[name=robots][content^=noindex]"
    end
  end

  test "the 404 page is never edge cached" do
    host! host_for(:books)

    get "/no-such-page-anywhere"

    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "a missing record is a 404 in the site layout" do
    host! host_for(:books)

    get "/lists/987654321"

    assert_response :not_found
    assert_select "html[data-theme=books]"
  end

  test "a missing record requested as json is still a 404" do
    host! host_for(:books)

    get "/lists/987654321.json"

    assert_response :not_found
  end

  test "a json client gets the static json 404, not the html page" do
    host! host_for(:books)

    get "/no-such-page-anywhere", headers: {"Accept" => "application/json"}

    assert_response :not_found
    assert_equal "application/json", response.media_type
  end

  test "a POST to an unknown path is a 404, not a forgery error" do
    host! host_for(:books)

    post "/no-such-page-anywhere"

    assert_response :not_found
    assert_select "html[data-theme=books]"
  end
end
