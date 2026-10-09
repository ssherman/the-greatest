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
module Books
  class RecommendationConfigTest < ActiveSupport::TestCase
    test "for_user returns the existing row" do
      existing = recommendation_configs(:regular_user_books)
      assert_equal existing, ::Books::RecommendationConfig.for_user(existing.user)
    end

    test "for_user initializes an unsaved row with empty criteria when none exists" do
      config = ::Books::RecommendationConfig.for_user(users(:editor_user))
      assert config.new_record?
      assert_equal({}, config.criteria)
      assert_equal [], config.criteria_object.excluded_category_ids
    end

    test "names its criteria params class" do
      assert_equal ::Books::RecommendationCriteriaParams, ::Books::RecommendationConfig.criteria_params_class
    end
  end
end
