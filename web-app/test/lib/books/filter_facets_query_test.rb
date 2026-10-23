require "test_helper"

module Books
  class FilterFacetsQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @rc, rank: 2, score: 90)
      RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 3, score: 80)
    end

    def categories_for(type, **options)
      Books::FilterFacetsQuery.categories(type: type, ranking_configuration: @rc, **options)
    end

    def countries_for(**options)
      Books::FilterFacetsQuery.countries(ranking_configuration: @rc, **options)
    end

    test "categories facet counts ranked books per genre" do
      counts = categories_for("genre").to_h { |row| [row[:record].slug, row[:count]] }

      # 3, not 2: war_and_peace, got, and crime_and_punishment (see
      # test/fixtures/category_items.yml) all carry novels_genre.
      assert_equal 3, counts["novels"]
      assert_equal 1, counts["classics"]
    end

    test "categories facet returns only the requested type" do
      slugs = categories_for("subject").map { |r| r[:record].slug }
      assert_includes slugs, "politics"
      assert_not_includes slugs, "novels"
    end

    test "categories facet keeps applied categories in the list with their counts" do
      novels = categories(:books_novels_genre)
      rows = categories_for("genre", categories: [novels])
      assert_equal 3, rows.find { |r| r[:record] == novels }[:count]
    end

    test "categories facet keeps the category filter applied and drills down" do
      counts = categories_for("genre", categories: [categories(:books_novels_genre)])
        .to_h { |row| [row[:record].slug, row[:count]] }

      assert_equal 1, counts["classics"]
    end

    test "applied categories are listed even with zero matching books" do
      americana = categories(:books_americana_genre) # no ranked books carry it
      rows = categories_for("genre", categories: [americana])
      assert_equal [americana, 0], [rows.last[:record], rows.last[:count]]
    end

    test "an applied category of another type is not listed" do
      politics = categories(:books_politics_subject)
      rows = categories_for("genre", categories: [politics])
      assert_not_includes rows.map { |r| r[:record] }, politics
    end

    test "categories facet limit caps the rows" do
      assert_equal 1, categories_for("genre", limit: 1).size
    end

    test "no limit returns every row" do
      assert_operator categories_for("genre").size, :>, 1
    end

    test "an unknown type raises" do
      assert_raises(ArgumentError) { categories_for("theme") }
    end

    test "orders by count descending" do
      counts = categories_for("genre").map { |row| row[:count] }

      assert_equal counts.sort.reverse, counts
    end

    test "audience facet lists audiences" do
      audience = Books::Category.create!(name: "Young Adult", category_type: :audience)
      CategoryItem.create!(category: audience, item: books_books(:crime_and_punishment))
      rows = categories_for("audience")
      assert_equal [[audience, 1]], rows.map { |r| [r[:record], r[:count]] }
    end

    test "countries facet counts ranked books per country" do
      counts = countries_for.to_h { |row| [row[:record].slug, row[:count]] }

      assert_equal 2, counts["french"]
    end

    test "countries facet keeps an applied country in the list" do
      french = books_countries(:french)
      rows = countries_for(countries: [french])
      assert_equal 2, rows.find { |r| r[:record] == french }[:count]
    end

    test "countries facet drops its own filter so alternatives remain visible" do
      Books::BookCountry.create!(book: books_books(:crime_and_punishment), country: books_countries(:japanese))

      slugs = countries_for(countries: [books_countries(:french)]).map { |row| row[:record].slug }

      assert_includes slugs, "japanese"
    end

    test "an applied country with no ranked books is listed with zero" do
      japanese = books_countries(:japanese) # of_mice_and_men is not ranked here
      rows = countries_for(countries: [japanese])
      assert_equal [japanese, 0], [rows.last[:record], rows.last[:count]]
    end

    test "countries facet excludes the unknown bucket" do
      Books::BookCountry.create!(book: books_books(:crime_and_punishment), country: books_countries(:unknown))

      slugs = countries_for.map { |row| row[:record].slug }

      assert_not_includes slugs, "unknown"
    end

    test "category counts are narrowed by the collection" do
      # crime_and_punishment has no country, so it drops out of the western
      # collection; giving it a genre here (instead of in the shared fixture)
      # is what makes that drop visible without perturbing every other test.
      CategoryItem.create!(category: categories(:books_fiction_genre), item: books_books(:crime_and_punishment))
      collection = ::Collections::Registry.find(:books, "western")

      scoped_total = categories_for("genre", collection: collection).sum { |row| row[:count] }
      unscoped_total = categories_for("genre").sum { |row| row[:count] }

      assert_operator scoped_total, :>, 0, "western should still count some genres"
      assert_operator scoped_total, :<, unscoped_total
    end
  end
end
