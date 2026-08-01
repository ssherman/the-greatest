require "test_helper"

module Books
  class ListsQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      @heavy = create_list("Heavy List", weight: 90, activated_at: 3.days.ago, source: "Guardian")
      @light = create_list("Light List", weight: 10, activated_at: 1.day.ago, source: "Times")
    end

    test "returns active books lists in the ranking configuration ordered by weight" do
      result = Books::ListsQuery.call(ranking_configuration: @rc)

      assert_equal [@heavy.list_id, @light.list_id], result.map(&:list_id)
    end

    test "excludes lists that are not active" do
      @light.list.update!(status: :unapproved)

      result = Books::ListsQuery.call(ranking_configuration: @rc)

      assert_equal [@heavy.list_id], result.map(&:list_id)
    end

    test "orders by activated_at descending for the newest sort" do
      result = Books::ListsQuery.call(ranking_configuration: @rc, sort: "newest")

      assert_equal [@light.list_id, @heavy.list_id], result.map(&:list_id)
    end

    test "puts lists with no activated_at last in the newest sort" do
      @light.list.update_column(:activated_at, nil)

      result = Books::ListsQuery.call(ranking_configuration: @rc, sort: "newest")

      assert_equal [@heavy.list_id, @light.list_id], result.map(&:list_id)
    end

    test "falls back to weight for an unrecognised sort" do
      result = Books::ListsQuery.call(ranking_configuration: @rc, sort: "'; DROP TABLE lists; --")

      assert_equal [@heavy.list_id, @light.list_id], result.map(&:list_id)
    end

    test "breaks weight ties by list id so pagination is stable" do
      tied = create_list("Tied List", weight: 90, activated_at: 5.days.ago)

      result = Books::ListsQuery.call(ranking_configuration: @rc)

      assert_equal [@heavy.list_id, tied.list_id, @light.list_id].sort, result.map(&:list_id).sort
      assert_operator result.map(&:list_id).index(@heavy.list_id), :<, result.map(&:list_id).index(tied.list_id)
    end

    test "filters by search across name, source and url" do
      assert_equal [@light.list_id], Books::ListsQuery.call(ranking_configuration: @rc, query: "Times").map(&:list_id)
      assert_equal [@heavy.list_id], Books::ListsQuery.call(ranking_configuration: @rc, query: "heavy").map(&:list_id)
    end

    test "ignores a blank search" do
      result = Books::ListsQuery.call(ranking_configuration: @rc, query: "   ")

      assert_equal 2, result.size
    end

    test "excludes lists belonging to another ranking configuration" do
      other = Books::RankingConfiguration.create!(name: "Other", global: true, primary: false, algorithm_version: 1)
      create_list("Elsewhere", weight: 99, ranking_configuration: other)

      result = Books::ListsQuery.call(ranking_configuration: @rc)

      assert_equal 2, result.size
    end

    private

    def create_list(name, weight:, activated_at: Time.current, source: nil, ranking_configuration: nil)
      list = Books::List.create!(name: name, source: source, status: :active)
      list.update_column(:activated_at, activated_at)
      RankedList.create!(list: list, ranking_configuration: ranking_configuration || @rc, weight: weight)
    end
  end
end
