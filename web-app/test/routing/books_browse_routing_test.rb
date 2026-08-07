require "test_helper"

class BooksBrowseRoutingTest < ActionDispatch::IntegrationTest
  HOST = Rails.application.config.domains[:books]

  BROWSE_CASES = [
    ["/genres", "genres", {}],
    ["/genres/page/2", "genres", {page: "2"}],
    ["/genres/sorted-by/name", "genres", {sort: "name"}],
    ["/genres/sorted-by/book_count/page/3", "genres", {sort: "book_count", page: "3"}],
    ["/genres/filtered-by/location", "genres", {filter: "location"}],
    ["/genres/filtered-by/subject/page/2", "genres", {filter: "subject", page: "2"}],
    ["/genres/filtered-by/subject/sorted-by/name", "genres", {filter: "subject", sort: "name"}],
    ["/genres/filtered-by/location/sorted-by/name/page/4",
      "genres", {filter: "location", sort: "name", page: "4"}],
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

  test "routes a category slug to the legacy show redirect" do
    assert_recognizes(
      {controller: "books/legacy_categories", action: "show", id: "fiction"},
      {path: "http://#{HOST}/genres/fiction", method: :get}
    )
  end

  # There is a real, active location category named "Page" (slug "page"), so the
  # bare path must resolve it while the paginated path stays pagination.
  test "the paginated genres path wins over the catch-all show route" do
    assert_recognizes(
      {controller: "books/browse", action: "genres", page: "2"},
      {path: "http://#{HOST}/genres/page/2", method: :get}
    )

    assert_recognizes(
      {controller: "books/legacy_categories", action: "show", id: "page"},
      {path: "http://#{HOST}/genres/page", method: :get}
    )
  end

  # There is a real, active subject category named "Search" (slug "search").
  # Legacy shadowed it with a JSON typeahead endpoint purely because collection
  # routes are declared before the member route; nothing points a JSON client at
  # this app, so it resolves as the category it is.
  test "the legacy search path resolves the category named Search" do
    assert_recognizes(
      {controller: "books/legacy_categories", action: "show", id: "search"},
      {path: "http://#{HOST}/genres/search", method: :get}
    )
  end

  # BrowseQuery.normalized_* silently falls back to the default for ANY input, so
  # without these constraints /genres/sorted-by/<anything> would be an unbounded
  # space of indexable soft-duplicates. An out-of-vocabulary sort must NOT reach
  # the controller -- it falls through to the show route, which 404s in Task 3.
  test "an out-of-vocabulary sort does not reach the browse action" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/genres/sorted-by/nonsense", method: :get)
    end

    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/countries/sorted-by/nonsense", method: :get)
    end
  end

  test "an out-of-vocabulary filter does not reach the browse action" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/genres/filtered-by/theme", method: :get)
    end
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
      assert_recognizes(
        {controller: "books/browse", action: "genres", filter: type},
        {path: "http://#{HOST}/genres/filtered-by/#{type}", method: :get}
      )
    end

    Books::BrowseQuery::SORTS.each do |sort|
      assert_recognizes(
        {controller: "books/browse", action: "genres", sort: sort},
        {path: "http://#{HOST}/genres/sorted-by/#{sort}", method: :get}
      )

      assert_recognizes(
        {controller: "books/browse", action: "countries", sort: sort},
        {path: "http://#{HOST}/countries/sorted-by/#{sort}", method: :get}
      )
    end
  end

  test "the bare browse helpers still generate the unparameterised paths" do
    assert_equal "/genres", Rails.application.routes.url_helpers.books_genres_path
    assert_equal "/genres/page/2", Rails.application.routes.url_helpers.books_genres_page_path(page: 2)
    assert_equal "/countries", Rails.application.routes.url_helpers.books_countries_path
    assert_equal "/countries/page/2", Rails.application.routes.url_helpers.books_countries_page_path(page: 2)
  end
end
