# frozen_string_literal: true

require "test_helper"

module Recommendations
  class NeighborScoresTest < ActiveSupport::TestCase
    def setup
      @model = RecommendationModel.create!(domain: "books", version: "v", state: :active)
      other = RecommendationModel.create!(domain: "books", version: "old", state: :retired)
      [[1, 10, 0.5], [1, 11, 0.2], [2, 10, 0.4], [2, 12, 0.9], [3, 13, 0.1]].each do |i, n, w|
        @model.recommendation_item_neighbors.create!(item_id: i, neighbor_id: n, weight: w)
      end
      other.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 14, weight: 5.0)
    end

    test "sums weights per neighbour over the shelf, names the strongest contributor, and ignores other models" do
      rows = NeighborScores.call(model: @model, shelf_ids: [1, 2], excluded_ids: [], limit: 10)
      assert_equal [10, 12, 11], rows.map { |r| r[:item_id] }, "10 and 12 tie at 0.9; the lower neighbour id wins the tie"
      ten = rows.find { |r| r[:item_id] == 10 }
      assert_in_delta 0.9, ten[:score], 1e-9
      assert_equal 1, ten[:because_of], "item 1 contributed 0.5, item 2 contributed 0.4"
      assert_in_delta 0.5, ten[:term], 1e-9
      assert_not_includes rows.map { |r| r[:item_id] }, 14
    end

    test "excludes shelved ids and honours the limit" do
      rows = NeighborScores.call(model: @model, shelf_ids: [1, 2], excluded_ids: [12], limit: 1)
      assert_equal [10], rows.map { |r| r[:item_id] }
    end

    test "an empty shelf asks nothing" do
      assert_equal [], NeighborScores.call(model: @model, shelf_ids: [], excluded_ids: [], limit: 10)
    end
  end
end
