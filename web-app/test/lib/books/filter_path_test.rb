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

    test "a single facet is indexable" do
      assert Books::FilterPath.indexable?(categories: [categories(:books_novels_genre)], countries: [])
      assert Books::FilterPath.indexable?(categories: [], countries: [books_countries(:french)])
    end

    test "no filters at all is indexable" do
      assert Books::FilterPath.indexable?(categories: [], countries: [])
    end

    test "one category plus one country stays indexable" do
      assert Books::FilterPath.indexable?(
        categories: [categories(:books_novels_genre)],
        countries: [books_countries(:french)]
      )
    end

    test "two categories are not indexable" do
      assert_not Books::FilterPath.indexable?(
        categories: [categories(:books_novels_genre), categories(:books_fiction_genre)],
        countries: []
      )
    end

    test "two countries are not indexable" do
      assert_not Books::FilterPath.indexable?(
        categories: [],
        countries: [books_countries(:french), books_countries(:japanese)]
      )
    end

    test "the comma in a path marks exactly the non-indexable set" do
      # robots.txt disallows on the comma, so the comma has to track indexable?
      # exactly -- including under an /rc/ prefix, which the rules only reach
      # because they lead with /*.
      alternate = Books::RankingConfiguration.new(id: 52, primary: false)
      pairs = [
        [[categories(:books_novels_genre)], [], nil],
        [[categories(:books_novels_genre), categories(:books_fiction_genre)], [], nil],
        [[], [books_countries(:french), books_countries(:japanese)], nil],
        [[categories(:books_novels_genre)], [], alternate],
        [[categories(:books_novels_genre), categories(:books_fiction_genre)], [], alternate],
        [[], [books_countries(:french), books_countries(:japanese)], alternate]
      ]

      pairs.each do |cats, countries, rc|
        path = Books::FilterPath.call(categories: cats, countries: countries, ranking_configuration: rc)
        assert_equal !path.include?(","), Books::FilterPath.indexable?(categories: cats, countries: countries)
      end
    end
  end
end
