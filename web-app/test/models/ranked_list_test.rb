# == Schema Information
#
# Table name: ranked_lists
#
#  id                        :bigint           not null, primary key
#  calculated_weight_details :jsonb
#  weight                    :integer
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  list_id                   :bigint           not null
#  ranking_configuration_id  :bigint           not null
#
# Indexes
#
#  index_ranked_lists_on_list_id                   (list_id)
#  index_ranked_lists_on_ranking_configuration_id  (ranking_configuration_id)
#
# Foreign Keys
#
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id)
#
require "test_helper"

class RankedListTest < ActiveSupport::TestCase
  def setup
    @books_config = ranking_configurations(:books_global)
    @books_list = lists(:books_list)
    @movies_config = ranking_configurations(:movies_global)
    @movies_list = lists(:movies_list)
  end

  test "should be valid with correct types" do
    # Create fresh test data to avoid fixture conflicts
    test_config = Books::RankingConfiguration.create!(
      name: "Test Config #{SecureRandom.hex(4)}",
      global: true,
      min_list_weight: 1
    )
    test_list = Books::List.create!(
      name: "Test List #{SecureRandom.hex(4)}",
      status: :approved
    )

    ranked_list = RankedList.new(
      ranking_configuration: test_config,
      list: test_list
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
    # Create fresh test data to avoid fixture conflicts
    test_config = Books::RankingConfiguration.create!(
      name: "Test Config #{SecureRandom.hex(4)}",
      global: true,
      min_list_weight: 1
    )
    test_list = Books::List.create!(
      name: "Test List #{SecureRandom.hex(4)}",
      status: :approved
    )

    # First entry should be valid
    first_entry = RankedList.create!(ranking_configuration: test_config, list: test_list)
    assert first_entry.valid?

    # Duplicate should not be valid
    duplicate = RankedList.new(ranking_configuration: test_config, list: test_list)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:list_id], "can only be added once per ranking configuration"
  end

  test "should allow same list in different ranking configurations" do
    # Create fresh test data to avoid fixture conflicts
    test_list = Books::List.create!(
      name: "Test List for Multiple Configs",
      status: :approved
    )

    # Create two different ranking configurations (completely separate from fixtures)
    config1 = Books::RankingConfiguration.create!(
      name: "First Books Config #{SecureRandom.hex(4)}",
      global: true,
      min_list_weight: 1
    )
    config2 = Books::RankingConfiguration.create!(
      name: "Second Books Config #{SecureRandom.hex(4)}",
      global: true,
      min_list_weight: 1
    )

    # Should be able to add the same list to both configurations
    RankedList.create!(ranking_configuration: config1, list: test_list)
    ranked_list2 = RankedList.new(ranking_configuration: config2, list: test_list)

    assert ranked_list2.valid?, "Same list should be allowed in different ranking configurations"

    # Verify it actually saves
    assert ranked_list2.save, "Should be able to save the same list to a different ranking configuration"
  end

  test "should allow null weight" do
    # Create fresh test data to avoid fixture conflicts
    test_config = Books::RankingConfiguration.create!(
      name: "Test Config #{SecureRandom.hex(4)}",
      global: true,
      min_list_weight: 1
    )
    test_list = Books::List.create!(
      name: "Test List #{SecureRandom.hex(4)}",
      status: :approved
    )

    ranked_list = RankedList.new(ranking_configuration: test_config, list: test_list, weight: nil)
    assert ranked_list.valid?
  end

  test "should belong to ranking_configuration and list" do
    # Create fresh test data to avoid fixture conflicts
    test_config = Books::RankingConfiguration.create!(
      name: "Test Config #{SecureRandom.hex(4)}",
      global: true,
      min_list_weight: 1
    )
    test_list = Books::List.create!(
      name: "Test List #{SecureRandom.hex(4)}",
      status: :approved
    )

    ranked_list = RankedList.new(ranking_configuration: test_config, list: test_list)
    assert_equal test_config, ranked_list.ranking_configuration
    assert_equal test_list, ranked_list.list
  end
end
