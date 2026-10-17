require "test_helper"

class BooksBrowseRoutingTest < ActionDispatch::IntegrationTest
  HOST = Rails.application.config.domains[:books]

  BROWSE_CASES = [
    ["/categories", "categories", {}],
    ["/categories/page/2", "categories", {page: "2"}],
    ["/categories/sorted-by/name", "categories", {sort: "name"}],
    ["/categories/sorted-by/book_count/page/3", "categories", {sort: "book_count", page: "3"}],
    ["/categories/settings", "categories", {filter: "location"}],
    ["/categories/settings/page/2", "categories", {filter: "location", page: "2"}],
    ["/categories/settings/sorted-by/name/page/4",
      "categories", {filter: "location", sort: "name", page: "4"}],
    ["/categories/subjects", "categories", {filter: "subject"}],
    ["/categories/subjects/sorted-by/name", "categories", {filter: "subject", sort: "name"}],
    ["/categories/subjects/page/2", "categories", {filter: "subject", page: "2"}],
    ["/countries", "countries", {}],
    ["/countries/page/2", "countries", {page: "2"}],
    ["/countries/sorted-by/name", "countries", {sort: "name"}],
    ["/countries/sorted-by/name/page/5", "countries", {sort: "name", page: "5"}]
  ].freeze

  BROWSE_CASES.each do |path, action, expected|
    test "routes #{path} to browse##{action}" do
      assert_recognizes(
        {controller: "books/browse", action: action}.merge(expected),
        {path: "http://#{HOST}#{path}", method: :get}
      )
    end
  end

  # BrowseQuery.normalized_* silently falls back to the default for ANY input, so
  # without these constraints /categories/sorted-by/<anything> would be an
  # unbounded space of indexable soft-duplicates. An out-of-vocabulary sort must
  # NOT reach the controller.
  test "an out-of-vocabulary sort does not reach the browse action" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/categories/sorted-by/nonsense", method: :get)
    end

    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/countries/sorted-by/nonsense", method: :get)
    end
  end

  test "an unknown type segment does not route" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/categories/theme", method: :get)
    end
  end

  test "a non-numeric category page does not route" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/categories/settings/page/x", method: :get)
    end
  end

  # /genres/<anything> is the legacy category page. Every other /genres shape
  # is a redirect route, so none of them recognizes to a controller action.
  test "genres/:id still routes to the legacy category show" do
    assert_recognizes(
      {controller: "books/legacy_categories", action: "show", id: "fiction"},
      {path: "http://#{HOST}/genres/fiction", method: :get}
    )
  end

  test "a non-numeric page does not route" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/countries/page/abc", method: :get)
    end
  end

  # /countries has no legacy show route, so an unknown countries path must 404
  # rather than silently resolving something.
  test "there is no countries show route" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/countries/french", method: :get)
    end
  end

  # config/routes.rb spells the vocabulary out as literal regexps because routes
  # are drawn before eager loading and referencing an autoloaded constant there
  # pins it across reloads. This is what keeps that copy honest: adding a value to
  # BrowseQuery without widening the route constraint would otherwise silently
  # produce a filter the app offers but cannot serve.
  test "every BrowseQuery type and sort is actually routable" do
    Books::BrowseQuery::TYPES.each do |type|
      segment = Books::BrowsePath::TYPE_SEGMENTS[type]
      next if segment.nil?

      assert_recognizes(
        {controller: "books/browse", action: "categories", filter: type},
        {path: "http://#{HOST}/categories/#{segment}", method: :get}
      )
    end

    Books::BrowseQuery::SORTS.each do |sort|
      assert_recognizes(
        {controller: "books/browse", action: "categories", sort: sort},
        {path: "http://#{HOST}/categories/sorted-by/#{sort}", method: :get}
      )

      assert_recognizes(
        {controller: "books/browse", action: "countries", sort: sort},
        {path: "http://#{HOST}/countries/sorted-by/#{sort}", method: :get}
      )
    end
  end

  test "the bare browse helpers still generate the unparameterised paths" do
    assert_equal "/categories", Rails.application.routes.url_helpers.books_categories_path
    assert_equal "/countries", Rails.application.routes.url_helpers.books_countries_path
    assert_equal "/countries/page/2", Rails.application.routes.url_helpers.books_countries_page_path(page: 2)
  end
end
