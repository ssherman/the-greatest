require "test_helper"

module Books
  class FilterFacetsQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @rc, rank: 2, score: 90)
      RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 3, score: 80)
    end

    def facets(**options)
      Books::FilterFacetsQuery.call(ranking_configuration: @rc, **options)
    end

    test "genre facet counts ranked books per genre" do
      counts = facets.genres.to_h { |row| [row[:record].slug, row[:count]] }

      assert_equal 2, counts["novels"]
      assert_equal 1, counts["classics"]
    end

    test "genre facet excludes non-genre category types" do
      slugs = facets.genres.map { |row| row[:record].slug }

      assert_not_includes slugs, "politics"
      assert_not_includes slugs, "france"
    end

    test "genre facet keeps the category filter applied and drills down" do
      counts = facets(categories: [categories(:books_novels_genre)])
        .genres.to_h { |row| [row[:record].slug, row[:count]] }

      assert_equal 1, counts["classics"]
    end

    test "genre facet excludes already-selected categories" do
      slugs = facets(categories: [categories(:books_novels_genre)]).genres.map { |row| row[:record].slug }

      assert_not_includes slugs, "novels"
    end

    test "country facet counts ranked books per country" do
      counts = facets.countries.to_h { |row| [row[:record].slug, row[:count]] }

      assert_equal 2, counts["french"]
    end

    test "country facet drops its own filter so alternatives remain visible" do
      Books::BookCountry.create!(book: books_books(:crime_and_punishment), country: books_countries(:japanese))

      slugs = facets(countries: [books_countries(:french)]).countries.map { |row| row[:record].slug }

      assert_includes slugs, "japanese"
    end

    test "country facet excludes already-selected countries" do
      slugs = facets(countries: [books_countries(:french)]).countries.map { |row| row[:record].slug }

      assert_not_includes slugs, "french"
    end

    test "country facet excludes the unknown bucket" do
      Books::BookCountry.create!(book: books_books(:crime_and_punishment), country: books_countries(:unknown))

      slugs = facets.countries.map { |row| row[:record].slug }

      assert_not_includes slugs, "unknown"
    end

    test "respects the limit" do
      assert_operator facets(limit: 1).genres.size, :<=, 1
    end

    test "orders by count descending" do
      counts = facets.genres.map { |row| row[:count] }

      assert_equal counts.sort.reverse, counts
    end

    test "DEFAULT_LIMIT is small enough for a phone-sized pane" do
      assert_equal 24, Books::FilterFacetsQuery::DEFAULT_LIMIT
    end

    test "genres can be queried on their own" do
      rows = Books::FilterFacetsQuery.genres(ranking_configuration: @rc)
      counts = rows.to_h { |row| [row[:record].slug, row[:count]] }

      assert_equal 2, counts["novels"]
      assert_equal 1, counts["classics"]
    end

    test "countries can be queried on their own" do
      rows = Books::FilterFacetsQuery.countries(ranking_configuration: @rc)
      counts = rows.to_h { |row| [row[:record].slug, row[:count]] }

      assert_equal 2, counts["french"]
    end

    test "the per-axis methods match what call returns" do
      result = facets

      assert_equal result.genres, Books::FilterFacetsQuery.genres(ranking_configuration: @rc)
      assert_equal result.countries, Books::FilterFacetsQuery.countries(ranking_configuration: @rc)
    end

    test "the per-axis genre method keeps the category filter applied" do
      rows = Books::FilterFacetsQuery.genres(
        ranking_configuration: @rc,
        categories: [categories(:books_novels_genre)]
      )
      slugs = rows.map { |row| row[:record].slug }

      assert_includes slugs, "classics"
      assert_not_includes slugs, "novels"
    end

    test "the per-axis country method drops its own filter" do
      Books::BookCountry.create!(book: books_books(:crime_and_punishment), country: books_countries(:japanese))

      rows = Books::FilterFacetsQuery.countries(
        ranking_configuration: @rc,
        countries: [books_countries(:french)]
      )
      slugs = rows.map { |row| row[:record].slug }

      assert_includes slugs, "japanese"
      assert_not_includes slugs, "french"
    end

    test "the per-axis methods respect the limit" do
      assert_operator Books::FilterFacetsQuery.genres(ranking_configuration: @rc, limit: 1).size, :<=, 1
      assert_operator Books::FilterFacetsQuery.countries(ranking_configuration: @rc, limit: 1).size, :<=, 1
    end
  end
end
