# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: recommendation_item_neighbors
#
#  id                      :bigint           not null, primary key
#  weight                  :float            not null
#  item_id                 :bigint           not null
#  neighbor_id             :bigint           not null
#  recommendation_model_id :bigint           not null
#
# Indexes
#
#  idx_on_recommendation_model_id_item_id_65911a84a9  (recommendation_model_id,item_id)
#
# Foreign Keys
#
#  fk_rails_...  (recommendation_model_id => recommendation_models.id)
#
class RecommendationItemNeighborTest < ActiveSupport::TestCase
  test "belongs to a model and requires a weight" do
    model = RecommendationModel.create!(domain: "books", version: "v")
    row = model.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 2, weight: 0.25)
    assert_equal model, row.recommendation_model
    assert_raises(ActiveRecord::NotNullViolation) { model.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 3, weight: nil) }
  end
end
