# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: recommendation_configs
#
#  id         :bigint           not null, primary key
#  criteria   :jsonb            not null
#  type       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
# Indexes
#
#  index_recommendation_configs_on_user_id           (user_id)
#  index_recommendation_configs_on_user_id_and_type  (user_id,type) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class RecommendationConfigTest < ActiveSupport::TestCase
  test "subclass_for resolves books and nothing else" do
    assert_equal ::Books::RecommendationConfig, RecommendationConfig.subclass_for("books")
    assert_equal ::Books::RecommendationConfig, RecommendationConfig.subclass_for(:books)
    assert_nil RecommendationConfig.subclass_for("music")
  end

  test "one config per user per type" do
    existing = recommendation_configs(:regular_user_books)
    dup = ::Books::RecommendationConfig.new(user: existing.user, criteria: {})
    assert_not dup.valid?
    assert_includes dup.errors[:user_id], "has already been taken"
  end

  test "criteria_object is typed and resets when criteria is reassigned" do
    config = recommendation_configs(:regular_user_books)
    assert_equal 500, config.criteria_object.max_ranked_position
    config.criteria = {"max_ranked_position" => "40"}
    assert_equal 40, config.criteria_object.max_ranked_position
  end

  test "destroying a user destroys its configs" do
    user = recommendation_configs(:regular_user_books).user
    assert_difference("RecommendationConfig.count", -1) { user.destroy! }
  end
end
