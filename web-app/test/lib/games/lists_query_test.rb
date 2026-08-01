require "test_helper"

module Games
  class ListsQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:games_global)
      @heavy = create_list("Heavy Games List", weight: 90, activated_at: 3.days.ago, source: "IGN")
      @light = create_list("Light Games List", weight: 10, activated_at: 1.day.ago, source: "Polygon")
    end

    test "returns active games lists ordered by weight" do
      result = Games::ListsQuery.call(ranking_configuration: @rc)

      assert_equal [@heavy.list_id, @light.list_id], result.map(&:list_id)
    end

    test "excludes lists that are not active" do
      @light.list.update!(status: :unapproved)

      assert_equal [@heavy.list_id], Games::ListsQuery.call(ranking_configuration: @rc).map(&:list_id)
    end

    test "orders by activated_at descending for the newest sort" do
      result = Games::ListsQuery.call(ranking_configuration: @rc, sort: "newest")

      assert_equal [@light.list_id, @heavy.list_id], result.map(&:list_id)
    end

    test "filters by search" do
      assert_equal [@light.list_id], Games::ListsQuery.call(ranking_configuration: @rc, query: "Polygon").map(&:list_id)
    end

    test "returns only games lists" do
      result = Games::ListsQuery.call(ranking_configuration: @rc)

      assert result.all? { |ranked_list| ranked_list.list.is_a?(Games::List) }
    end

    private

    def create_list(name, weight:, activated_at: Time.current, source: nil)
      list = Games::List.create!(name: name, source: source, status: :active)
      list.update_column(:activated_at, activated_at)
      RankedList.create!(list: list, ranking_configuration: @rc, weight: weight)
    end
  end
end
