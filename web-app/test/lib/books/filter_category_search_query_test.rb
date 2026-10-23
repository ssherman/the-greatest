require "test_helper"

module Books
  class FilterCategorySearchQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @rc, rank: 2, score: 90)
      @alias_hit = Books::Category.create!(name: "Statecraft", category_type: :subject, alternative_names: ["Politics Junk"])
      CategoryItem.create!(category: @alias_hit, item: books_books(:war_and_peace))
      CategoryItem.create!(category: @alias_hit, item: books_books(:crime_and_punishment))
      # Politics has one book link; the threshold tests raise this themselves.
      @original_minimum = Rails.configuration.x.books.browse_min_category_books
      Rails.configuration.x.books.browse_min_category_books = 1
    end

    teardown { Rails.configuration.x.books.browse_min_category_books = @original_minimum }

    def search(q, type: "subject", **opts) = Books::FilterCategorySearchQuery.call(query: q, type: type, ranking_configuration: @rc, **opts)

    test "a name match outranks a more common alias-only match" do
      assert_equal [categories(:books_politics_subject), @alias_hit], search("politics")
    end

    test "results are limited to the requested type" do
      assert_empty search("novels")
    end

    test "results are limited to categories with books under the applied filters" do
      assert_equal [@alias_hit], search("politic", categories: [categories(:books_classics_genre)])
    end

    test "a subject under the browse minimum of book links is hidden; one at it is listed" do
      Rails.configuration.x.books.browse_min_category_books = 2

      # Politics: one ranked book link and a fixture item_count of 200, so only
      # the book-link count can hide it. Statecraft: two ranked book links.
      assert_equal [@alias_hit], search("politic")
    end

    test "author links do not count toward the browse minimum" do
      Rails.configuration.x.books.browse_min_category_books = 2
      place = Books::Category.create!(name: "Authorland", category_type: :location)
      CategoryItem.create!(category: place, item: books_books(:war_and_peace))
      3.times { |n| CategoryItem.create!(category: place, item: Books::Author.create!(name: "Writer #{n}")) }
      control = Books::Category.create!(name: "Authorland Heights", category_type: :location)
      CategoryItem.create!(category: control, item: books_books(:war_and_peace))
      CategoryItem.create!(category: control, item: books_books(:crime_and_punishment))

      assert_equal [control], search("authorland", type: "location")
    end

    test "genres are exempt from the browse minimum" do
      Rails.configuration.x.books.browse_min_category_books = 5
      genre = Books::Category.create!(name: "Zzyzx Fiction", category_type: :genre)
      CategoryItem.create!(category: genre, item: books_books(:war_and_peace))

      assert_equal [genre], search("zzyzx", type: "genre")
    end

    test "a blank query returns nothing" do
      assert_empty search("  ")
    end

    test "an over-long query returns nothing" do
      assert_empty search("a" * 101)
    end

    test "an unknown type raises" do
      assert_raises(ArgumentError) do
        Books::FilterCategorySearchQuery.call(query: "x", type: "country", ranking_configuration: @rc)
      end
    end
  end
end
