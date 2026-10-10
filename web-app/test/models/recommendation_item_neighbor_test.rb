# frozen_string_literal: true

require "test_helper"

class RecommendationItemNeighborTest < ActiveSupport::TestCase
  test "belongs to a model and requires a weight" do
    model = RecommendationModel.create!(domain: "books", version: "v")
    row = model.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 2, weight: 0.25)
    assert_equal model, row.recommendation_model
    assert_raises(ActiveRecord::NotNullViolation) { model.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 3, weight: nil) }
  end
end
