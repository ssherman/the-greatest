# == Schema Information
#
# Table name: ranked_items
#
#  id                       :bigint           not null, primary key
#  item_type                :string           not null
#  rank                     :integer
#  score                    :decimal(10, 2)
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  item_id                  :bigint           not null
#  ranking_configuration_id :bigint           not null
#
# Indexes
#
#  index_ranked_items_on_config_and_rank                 (ranking_configuration_id,rank)
#  index_ranked_items_on_config_and_score                (ranking_configuration_id,score)
#  index_ranked_items_on_item                            (item_type,item_id)
#  index_ranked_items_on_item_and_ranking_config_unique  (item_id,item_type,ranking_configuration_id) UNIQUE
#  index_ranked_items_on_ranking_configuration_id        (ranking_configuration_id)
#
# Foreign Keys
#
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id)
#
require "test_helper"

class RankedItemTest < ActiveSupport::TestCase
  def setup
    @movies_config = ranking_configurations(:movies_global)
    @music_config = ranking_configurations(:music_global)
    @godfather = movies_movies(:godfather)
    @dark_side = music_albums(:dark_side_of_the_moon)
    @wish_you_were_here = music_albums(:wish_you_were_here)
  end

  test "should be valid with correct types" do
    ranked_item = RankedItem.new(
      ranking_configuration: @movies_config,
      item: @godfather
    )
    assert ranked_item.valid?
  end

  test "should not allow mismatched types" do
    ranked_item = RankedItem.new(
      ranking_configuration: @movies_config,
      item: @dark_side
    )
    assert_not ranked_item.valid?
    assert_includes ranked_item.errors[:item], "must be a Movies::Movie"
  end

  test "should enforce uniqueness per ranking configuration" do
    # Use a different movie that's not already in fixtures
    shawshank = movies_movies(:shawshank)
    RankedItem.create!(ranking_configuration: @movies_config, item: shawshank)
    duplicate = RankedItem.new(ranking_configuration: @movies_config, item: shawshank)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:item_id], "can only be ranked once per ranking configuration"
  end

  test "should allow same item in different ranking configurations" do
    other_config = RankingConfiguration.create!(
      name: "Other Movies Config",
      type: "Movies::RankingConfiguration"
    )
    # Use a different movie that's not already in fixtures
    shawshank = movies_movies(:shawshank)
    RankedItem.create!(ranking_configuration: @movies_config, item: shawshank)
    ranked_item = RankedItem.new(ranking_configuration: other_config, item: shawshank)
    assert ranked_item.valid?
  end

  test "should allow null rank and score" do
    # Use a different movie that's not already in fixtures
    shawshank = movies_movies(:shawshank)
    ranked_item = RankedItem.new(
      ranking_configuration: @movies_config,
      item: shawshank,
      rank: nil,
      score: nil
    )
    assert ranked_item.valid?
  end

  test "should belong to ranking_configuration and item" do
    ranked_item = RankedItem.new(ranking_configuration: @movies_config, item: @godfather)
    assert_equal @movies_config, ranked_item.ranking_configuration
    assert_equal @godfather, ranked_item.item
  end

  test "should accept music albums in music ranking configuration" do
    # Use a different album that's not already in fixtures
    ranked_item = RankedItem.new(
      ranking_configuration: @music_config,
      item: @wish_you_were_here
    )
    assert ranked_item.valid?
  end

  test "should accept music songs in music ranking configuration" do
    # Skip this test for now since we don't have song fixtures
    skip "No song fixtures available"
  end

  test "by_rank scope should order by rank" do
    # Create test data for this scope test
    config = ranking_configurations(:movies_global)
    item1 = movies_movies(:godfather)
    item2 = movies_movies(:shawshank)

    ranked_item1 = RankedItem.create!(ranking_configuration: config, item: item1, rank: 2, score: 8.5)
    ranked_item2 = RankedItem.create!(ranking_configuration: config, item: item2, rank: 1, score: 9.0)

    ordered = RankedItem.by_rank
    assert_equal ranked_item2, ordered.first  # rank 1 should come first
    assert_equal ranked_item1, ordered.second # rank 2 should come second
  end

  test "by_score scope should order by score descending" do
    # Create test data for this scope test
    config = ranking_configurations(:movies_global)
    item1 = movies_movies(:godfather)
    item2 = movies_movies(:shawshank)

    ranked_item1 = RankedItem.create!(ranking_configuration: config, item: item1, rank: 1, score: 8.5)
    ranked_item2 = RankedItem.create!(ranking_configuration: config, item: item2, rank: 2, score: 9.0)

    ordered = RankedItem.by_score
    assert_equal ranked_item2, ordered.first  # score 9.0 should come first
    assert_equal ranked_item1, ordered.second # score 8.5 should come second
  end
end
