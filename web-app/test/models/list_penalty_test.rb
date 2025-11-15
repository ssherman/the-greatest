# == Schema Information
#
# Table name: list_penalties
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  list_id    :bigint           not null
#  penalty_id :bigint           not null
#
# Indexes
#
#  index_list_penalties_on_list_and_penalty  (list_id,penalty_id) UNIQUE
#  index_list_penalties_on_list_id           (list_id)
#  index_list_penalties_on_penalty_id        (penalty_id)
#
# Foreign Keys
#
#  fk_rails_...  (list_id => lists.id)
#  fk_rails_...  (penalty_id => penalties.id)
#
require "test_helper"

class ListPenaltyTest < ActiveSupport::TestCase
  setup do
    @music_list = lists(:music_albums_list)
    @books_list = lists(:books_list)
    @static_global_penalty = penalties(:global_penalty)
    @static_music_penalty = ::Music::Penalty.create!(name: "Static Music Penalty", description: "A static penalty")
    @dynamic_global_penalty = penalties(:dynamic_penalty)

    # Clean up any existing list_penalties for these lists to avoid uniqueness conflicts
    ListPenalty.where(list: [@music_list, @books_list]).destroy_all
  end

  test "should create list_penalty with static penalty" do
    list_penalty = ListPenalty.new(list: @music_list, penalty: @static_global_penalty)
    assert list_penalty.save
  end

  test "should not create list_penalty with dynamic penalty" do
    list_penalty = ListPenalty.new(list: @music_list, penalty: @dynamic_global_penalty)
    assert_not list_penalty.save
    assert_includes list_penalty.errors[:penalty], "dynamic penalties cannot be manually attached to lists"
  end

  test "should validate media type compatibility" do
    # Create a static books penalty for testing media type incompatibility
    books_penalty = Books::Penalty.create!(name: "Static Books Penalty", description: "A static books penalty")
    list_penalty = ListPenalty.new(list: @music_list, penalty: books_penalty)
    assert_not list_penalty.save
    assert list_penalty.errors[:penalty].any? { |msg| msg.include?("books penalty cannot be applied to") }
  end

  test "should allow global penalty on any list type" do
    list_penalty = ListPenalty.new(list: @books_list, penalty: @static_global_penalty)
    assert list_penalty.save
  end

  test "should allow media-specific penalty on matching list type" do
    list_penalty = ListPenalty.new(list: @music_list, penalty: @static_music_penalty)
    assert list_penalty.save
  end

  test "should enforce uniqueness of list and penalty combination" do
    ListPenalty.create!(list: @music_list, penalty: @static_global_penalty)
    duplicate = ListPenalty.new(list: @music_list, penalty: @static_global_penalty)
    assert_not duplicate.save
    assert_includes duplicate.errors[:list_id], "has already been taken"
  end

  test "#static_penalty? returns true for static penalty" do
    list_penalty = ListPenalty.create!(list: @music_list, penalty: @static_global_penalty)
    assert list_penalty.static_penalty?
  end

  test "#global_penalty? returns true for global penalty" do
    list_penalty = ListPenalty.create!(list: @music_list, penalty: @static_global_penalty)
    assert list_penalty.global_penalty?
  end
end
