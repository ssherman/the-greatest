# frozen_string_literal: true

require "test_helper"

class RecommendationModelTest < ActiveSupport::TestCase
  test "version is unique per domain and active_for returns the one active model" do
    a = RecommendationModel.create!(domain: "books", version: "2026-10-01", state: :retired)
    b = RecommendationModel.create!(domain: "books", version: "2026-10-02", state: :active)
    assert_not RecommendationModel.new(domain: "books", version: "2026-10-02").valid?
    assert RecommendationModel.new(domain: "music", version: "2026-10-02").valid?
    assert_equal b, RecommendationModel.active_for(:books)
    assert_nil RecommendationModel.active_for(:music)
    assert_not_equal a, RecommendationModel.active_for("books")
  end

  test "deleting a model deletes its neighbours" do
    model = RecommendationModel.create!(domain: "books", version: "v")
    model.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 2, weight: 0.5)
    model.destroy!
    assert_equal 0, RecommendationItemNeighbor.count
  end
end
