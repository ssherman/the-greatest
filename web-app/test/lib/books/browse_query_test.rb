require "test_helper"

module Books
  class BrowseQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 2, score: 90)
      RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 3, score: 80)
      CategoryItem.create!(category: categories(:books_politics_subject), item: books_books(:war_and_peace))
    end

    def categories_for(**options)
      Books::BrowseQuery.categories(ranking_configuration: @rc, **options)
    end

    def countries_for(**options)
      Books::BrowseQuery.countries(ranking_configuration: @rc, **options)
    end

    test "categories returns only the requested type" do
      types = categories_for(type: "subject").map { |c| c.category_type.to_s }.uniq

      assert_equal ["subject"], types
    end

    test "categories defaults to genres" do
      types = categories_for.map { |c| c.category_type.to_s }.uniq

      assert_equal ["genre"], types
    end

    test "an unknown type falls back to genre rather than raising" do
      assert_equal categories_for.to_a, categories_for(type: "nonsense").to_a
    end

    test "categories excludes soft-deleted rows" do
      assert_not_includes categories_for.to_a, categories(:books_deleted_genre)
    end

    test "categories excludes a category whose books are none of them ranked" do
      fiction = categories(:books_fiction_genre)

      assert_operator fiction.item_count, :>, 0
      assert_not_includes categories_for.to_a, fiction
    end

    test "categories excludes a category ranked only in another configuration" do
      other = ranking_configurations(:books_inherited)
      empty = Books::Category.create!(name: "Elsewhere Genre", category_type: :genre)
      CategoryItem.create!(category: empty, item: books_books(:clash))
      RankedItem.create!(item: books_books(:clash), ranking_configuration: other, rank: 1, score: 10)

      assert_not_includes categories_for.to_a, empty
    end

    test "categories excludes other media types" do
      # A Music::Category that satisfies every other gate -- same category_type,
      # not deleted, and carrying a ranked Books::Book -- so only the STI scope
      # can keep it out.
      rock = categories(:music_rock_genre)
      CategoryItem.create!(category: rock, item: books_books(:war_and_peace))

      assert_not_includes categories_for(type: "genre").map(&:id), rock.id
    end

    test "categories counts only ranked books, not the catalog counter cache" do
      novels = categories_for.find { |c| c.slug == "novels" }

      assert_equal 2, novels.ranked_count
      assert_operator novels.item_count, :>, novels.ranked_count
    end

    test "categories sorts by ranked count then name by default" do
      slugs = categories_for.map(&:slug)

      assert_equal ["novels", "classics"], slugs
    end

    test "categories sorts by name on request" do
      names = categories_for(sort: "name").map(&:name)

      assert_equal names.sort, names
    end

    test "an unknown sort falls back to count rather than raising" do
      assert_equal categories_for.to_a, categories_for(sort: "nonsense").to_a
    end

    test "countries exclude the unknown bucket even when it holds ranked books" do
      # The production unknown bucket holds ~34,000 books, so the ranked-count
      # gate cannot exclude it -- only Books::Country.filterable can.
      Books::BookCountry.create!(book: books_books(:war_and_peace), country: books_countries(:unknown))

      slugs = countries_for.map(&:slug)

      assert_not_includes slugs, "unknown"
      assert_includes slugs, "french"
    end

    test "countries exclude a country whose books are none of them ranked" do
      algerian = books_countries(:algerian)

      assert_operator algerian.book_count, :>, 0
      assert_not_includes countries_for.map(&:id), algerian.id
    end

    test "countries count only ranked books" do
      french = countries_for.find { |c| c.slug == "french" }

      assert_equal 2, french.ranked_count
    end

    test "countries sort by ranked count then name by default" do
      slugs = countries_for.map(&:slug)

      assert_equal ["french", "japanese"], slugs
    end

    test "countries sort by name on request" do
      names = countries_for(sort: "name").map(&:name)

      assert_equal names.sort, names
    end

    test "both stay paginatable relations" do
      [categories_for, countries_for].each do |relation|
        assert_kind_of ActiveRecord::Relation, relation
        assert_kind_of Integer, relation.count(:all)
        assert_equal 1, relation.limit(1).offset(0).to_a.size
      end
    end
  end
end
