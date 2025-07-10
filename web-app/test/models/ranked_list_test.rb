require "test_helper"

class RankedListTest < ActiveSupport::TestCase
  def setup
    @books_config = ranking_configurations(:books_global)
    @books_list = lists(:books_list)
    @movies_config = ranking_configurations(:movies_global)
    @movies_list = lists(:movies_list)
  end

  test "should be valid with correct types" do
    ranked_list = RankedList.new(
      ranking_configuration: @books_config,
      list: @books_list
    )
    assert ranked_list.valid?
  end

  test "should not allow mismatched types" do
    ranked_list = RankedList.new(
      ranking_configuration: @books_config,
      list: @movies_list
    )
    assert_not ranked_list.valid?
    assert_includes ranked_list.errors[:list], "must be a Books::List"
  end

  test "should enforce uniqueness per ranking configuration" do
    RankedList.create!(ranking_configuration: @books_config, list: @books_list)
    duplicate = RankedList.new(ranking_configuration: @books_config, list: @books_list)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:list_id], "can only be added once per ranking configuration"
  end

  test "should allow same list in different ranking configurations" do
    other_config = RankingConfiguration.create!(
      name: "Other Books Config",
      type: "Books::RankingConfiguration"
    )
    RankedList.create!(ranking_configuration: @books_config, list: @books_list)
    ranked_list = RankedList.new(ranking_configuration: other_config, list: @books_list)

    assert ranked_list.valid?
  end

  test "should allow null weight" do
    ranked_list = RankedList.new(ranking_configuration: @books_config, list: @books_list, weight: nil)
    assert ranked_list.valid?
  end

  test "should belong to ranking_configuration and list" do
    ranked_list = RankedList.new(ranking_configuration: @books_config, list: @books_list)
    assert_equal @books_config, ranked_list.ranking_configuration
    assert_equal @books_list, ranked_list.list
  end
end
