require "test_helper"

module Books
  class FilterPathTest < ActiveSupport::TestCase
    def category(slug) = Books::Category.new(slug: slug)

    def country(slug) = Books::Country.new(slug: slug)

    test "no filters is the root path" do
      assert_equal "/", Books::FilterPath.call
    end

    test "no filters with a page" do
      assert_equal "/page/3", Books::FilterPath.call(page: 3)
    end

    test "page 1 is never emitted" do
      assert_equal "/", Books::FilterPath.call(page: 1)
    end

    test "a single category" do
      assert_equal "/the-greatest/novels/books", Books::FilterPath.call(categories: [category("novels")])
    end

    test "categories are sorted for canonicalization" do
      path = Books::FilterPath.call(categories: [category("novels"), category("fiction")])

      assert_equal "/the-greatest/fiction,novels/books", path
    end

    test "a country without a category" do
      path = Books::FilterPath.call(countries: [country("french")])

      assert_equal "/the-greatest-books/written-by/french/authors", path
    end

    test "countries are sorted for canonicalization" do
      path = Books::FilterPath.call(countries: [country("german"), country("french")])

      assert_equal "/the-greatest-books/written-by/french,german/authors", path
    end

    test "a category and a country" do
      path = Books::FilterPath.call(categories: [category("novels")], countries: [country("french")])

      assert_equal "/the-greatest/novels/books/written-by/french/authors", path
    end

    test "a single year" do
      path = Books::FilterPath.call(year_start: "1984", year_end: "1984")

      assert_equal "/the-greatest-books/of/1984", path
    end

    test "a start year only" do
      assert_equal "/the-greatest-books/since/1900", Books::FilterPath.call(year_start: "1900")
    end

    test "an end year only" do
      assert_equal "/the-greatest-books/to/1900", Books::FilterPath.call(year_end: "1900")
    end

    test "a full range" do
      path = Books::FilterPath.call(year_start: "1900", year_end: "2000")

      assert_equal "/the-greatest-books/from/1900/to/2000", path
    end

    test "everything at once, with a page" do
      path = Books::FilterPath.call(
        categories: [category("novels")],
        countries: [country("french")],
        year_start: "1900",
        year_end: "2000",
        page: 3
      )

      assert_equal "/the-greatest/novels/books/written-by/french/authors/from/1900/to/2000/page/3", path
    end

    test "a non-primary ranking configuration prefixes rc" do
      rc = Books::RankingConfiguration.new(id: 52, primary: false)
      path = Books::FilterPath.call(categories: [category("novels")], ranking_configuration: rc)

      assert_equal "/rc/52/the-greatest/novels/books", path
    end

    test "a primary ranking configuration adds no prefix" do
      rc = Books::RankingConfiguration.new(id: 8, primary: true)
      path = Books::FilterPath.call(categories: [category("novels")], ranking_configuration: rc)

      assert_equal "/the-greatest/novels/books", path
    end

    test "a non-primary ranking configuration with no filters" do
      rc = Books::RankingConfiguration.new(id: 52, primary: false)

      assert_equal "/rc/52", Books::FilterPath.call(ranking_configuration: rc)
    end
  end
end
