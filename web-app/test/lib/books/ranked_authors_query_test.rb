require "test_helper"

module Books
  class RankedAuthorsQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_authors_global)
      @second = RankedItem.create!(item: books_authors(:king), ranking_configuration: @rc, rank: 2, score: 90)
      @first = RankedItem.create!(item: books_authors(:tolstoy), ranking_configuration: @rc, rank: 1, score: 100)
    end

    test "returns the configuration's ranked authors ordered by rank" do
      assert_equal [@first, @second], Books::RankedAuthorsQuery.call(ranking_configuration: @rc).to_a
    end

    test "excludes items belonging to another ranking configuration" do
      other = ranking_configurations(:books_authors_secondary)
      RankedItem.create!(item: books_authors(:bachman), ranking_configuration: other, rank: 1, score: 50)

      results = Books::RankedAuthorsQuery.call(ranking_configuration: @rc)

      assert_equal 2, results.count
    end

    test "excludes ranked items with a null rank" do
      rankless = RankedItem.new(item: books_authors(:bachman), ranking_configuration: @rc, rank: nil, score: 5)
      rankless.save!(validate: false)

      results = Books::RankedAuthorsQuery.call(ranking_configuration: @rc)

      refute_includes results.map(&:rank), nil
      refute_includes results.map(&:item_id), books_authors(:bachman).id
    end

    test "excludes non-author ranked items" do
      RankedItem.new(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 3, score: 10).save!(validate: false)

      item_types = Books::RankedAuthorsQuery.call(ranking_configuration: @rc).map(&:item_type).uniq

      assert_equal ["Books::Author"], item_types
    end

    test "preloads descriptions so views do not N+1" do
      Description.create!(describable: @first.item, content: "Leo Tolstoy was a Russian writer.", kind: :summary, source: :manual)

      relation = Books::RankedAuthorsQuery.call(ranking_configuration: @rc)

      assert_queries_count(3) do
        relation.to_a.each { |ri| ri.item.descriptions.map(&:content) }
      end
    end
  end
end
