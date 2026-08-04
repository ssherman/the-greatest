require "test_helper"

class BooksFiltersRoutingTest < ActionDispatch::IntegrationTest
  CASES = [
    ["/the-greatest-books/of/1984", {year: "1984"}],
    ["/the-greatest-books/since/1900", {published_start: "1900"}],
    ["/the-greatest-books/to/1900", {published_end: "1900"}],
    ["/the-greatest-books/from/1900/to/2000", {published_start: "1900", published_end: "2000"}],
    ["/the-greatest-books/page/2", {page: "2"}],
    ["/the-greatest-books/written-by/french/authors", {country_id: "french"}],
    ["/the-greatest-books/written-by/french,german/authors/of/1984", {country_id: "french,german", year: "1984"}],
    ["/the-greatest/novels/books", {category_id: "novels"}],
    ["/the-greatest/novels,fiction/books/page/3", {category_id: "novels,fiction", page: "3"}],
    ["/the-greatest/novels/books/written-by/french/authors", {category_id: "novels", country_id: "french"}],
    ["/the-greatest/novels/books/written-by/french/authors/from/1900/to/2000/page/2",
      {category_id: "novels", country_id: "french", published_start: "1900", published_end: "2000", page: "2"}],
    ["/rc/52/the-greatest-books/since/1900", {ranking_configuration_id: "52", published_start: "1900"}],
    ["/rc/52/the-greatest/novels/books/written-by/french/authors/of/1984",
      {ranking_configuration_id: "52", category_id: "novels", country_id: "french", year: "1984"}]
  ].freeze

  HOST = Rails.application.config.domains[:books]

  CASES.each do |path, expected|
    test "routes #{path}" do
      assert_recognizes(
        {controller: "books/ranked_items", action: "index"}.merge(expected),
        {path: "http://#{HOST}#{path}", method: :get}
      )
    end
  end

  test "a non-numeric page does not route" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/the-greatest-books/page/abc", method: :get)
    end
  end

  test "the loop generates the expected number of routes" do
    count = Rails.application.routes.routes.count { |r| r.defaults[:controller] == "books/ranked_items" }
    assert_equal 84, count
  end
end
