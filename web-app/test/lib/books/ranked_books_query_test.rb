require "test_helper"

module Books
  class RankedBooksQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      @second = RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @rc, rank: 2, score: 90)
      @first = RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
    end

    test "returns the configuration's ranked books ordered by rank" do
      assert_equal [@first, @second], Books::RankedBooksQuery.call(ranking_configuration: @rc).to_a
    end

    test "excludes items belonging to another ranking configuration" do
      other = ranking_configurations(:books_inherited)
      RankedItem.create!(item: books_books(:got), ranking_configuration: other, rank: 1, score: 50)

      results = Books::RankedBooksQuery.call(ranking_configuration: @rc)

      assert_equal 2, results.count
    end

    test "excludes non-book ranked items" do
      RankedItem.new(item: music_albums(:dark_side_of_the_moon), ranking_configuration: @rc, rank: 3, score: 10).save!(validate: false)

      item_types = Books::RankedBooksQuery.call(ranking_configuration: @rc).map(&:item_type).uniq

      assert_equal ["Books::Book"], item_types
    end

    test "preloads authors and the primary image so views do not N+1" do
      relation = Books::RankedBooksQuery.call(ranking_configuration: @rc)

      assert_queries_count(5) do
        relation.to_a.each { |ri| ri.item.book_authors.map { |ba| ba.author.name } }
      end
    end
  end
end
