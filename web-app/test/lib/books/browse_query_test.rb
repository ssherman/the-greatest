require "test_helper"

module Books
  class BrowseQueryTest < ActiveSupport::TestCase
    test "categories returns only the requested type" do
      types = Books::BrowseQuery.categories(type: "subject").map { |c| c.category_type.to_s }.uniq

      assert_equal ["subject"], types
    end

    test "categories defaults to genres" do
      types = Books::BrowseQuery.categories.map { |c| c.category_type.to_s }.uniq

      assert_equal ["genre"], types
    end

    test "an unknown type falls back to genre rather than raising" do
      assert_equal Books::BrowseQuery.categories.to_a, Books::BrowseQuery.categories(type: "nonsense").to_a
    end

    test "categories excludes soft-deleted rows" do
      assert_not_includes Books::BrowseQuery.categories.to_a, categories(:books_deleted_genre)
    end

    test "categories excludes rows with no items" do
      empty = Books::Category.create!(name: "Empty Genre", category_type: :genre, item_count: 0)

      assert_not_includes Books::BrowseQuery.categories.to_a, empty
    end

    test "categories excludes other media types" do
      assert_not_includes Books::BrowseQuery.categories(type: "genre").to_a, categories(:music_rock_genre)
    end

    test "categories sorts by count then name by default" do
      counts = Books::BrowseQuery.categories.map(&:item_count)

      assert_equal counts.sort.reverse, counts
    end

    test "categories sorts by name on request" do
      names = Books::BrowseQuery.categories(sort: "name").map(&:name)

      assert_equal names.sort, names
    end

    test "an unknown sort falls back to count rather than raising" do
      assert_equal Books::BrowseQuery.categories.to_a, Books::BrowseQuery.categories(sort: "nonsense").to_a
    end

    test "countries exclude the unknown bucket and empty rows" do
      zero_count = Books::Country.create!(name: "Zero Books", slug: "zero-books", book_count: 0)
      slugs = Books::BrowseQuery.countries.map(&:slug)

      assert_not_includes slugs, "unknown"
      assert_not_includes slugs, zero_count.slug
      assert_includes slugs, "french"
    end

    test "countries sort by count then name by default" do
      counts = Books::BrowseQuery.countries.map(&:book_count)

      assert_equal counts.sort.reverse, counts
    end

    test "countries sort by name on request" do
      names = Books::BrowseQuery.countries(sort: "name").map(&:name)

      assert_equal names.sort, names
    end

    test "both return relations so the controller can paginate them" do
      assert_kind_of ActiveRecord::Relation, Books::BrowseQuery.categories
      assert_kind_of ActiveRecord::Relation, Books::BrowseQuery.countries
    end
  end
end
