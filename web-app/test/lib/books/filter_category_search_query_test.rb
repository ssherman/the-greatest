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
    end

    def search(q, **opts) = Books::FilterCategorySearchQuery.call(query: q, type: "subject", ranking_configuration: @rc, **opts)

    test "a name match outranks a more common alias-only match" do
      assert_equal [categories(:books_politics_subject), @alias_hit], search("politics")
    end

    test "results are limited to the requested type" do
      assert_empty search("novels")
    end

    test "results are limited to categories with books under the applied filters" do
      assert_equal [@alias_hit], search("politic", categories: [categories(:books_classics_genre)])
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
