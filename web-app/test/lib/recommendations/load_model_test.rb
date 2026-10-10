# frozen_string_literal: true

require "test_helper"
require "zlib"

module Recommendations
  class LoadModelTest < ActiveSupport::TestCase
    ROWS = [[1, 2, 0.9], [1, 3, 0.4], [2, 1, 0.8]].freeze

    def publish(store, version, rows: ROWS, manifest_rows: rows.size, latest: true)
      csv = "item_id,neighbor_id,weight\n" + rows.map { |r| r.join(",") }.join("\n") + "\n"
      store.put(Paths.model(:books, version), Zlib.gzip(csv))
      store.put(Paths.model_manifest(:books, version), JSON.generate({"domain" => "books", "export" => version, "rows" => manifest_rows, "items" => 2}))
      store.write_pointer(Paths.model_latest(:books), version) if latest
    end

    def setup
      @dir = Dir.mktmpdir
      @store = Store::Local.new(@dir)
    end

    test "loads latest, activates it, and stores the manifest" do
      publish(@store, "2026-10-09")
      result = LoadModel.call(domain: :books, store: @store)
      assert result.success?, result.errors.inspect
      assert result.data[:loaded]
      assert_equal 3, result.data[:rows]
      model = RecommendationModel.active_for(:books)
      assert_equal "2026-10-09", model.version
      assert_equal 3, model.manifest["rows"]
      assert_equal [[1, 2, 0.9], [1, 3, 0.4], [2, 1, 0.8]], model.recommendation_item_neighbors.order(:item_id, weight: :desc).pluck(:item_id, :neighbor_id, :weight)
    end

    test "a second run for the same version does nothing" do
      publish(@store, "2026-10-09")
      LoadModel.call(domain: :books, store: @store)
      result = LoadModel.call(domain: :books, store: @store)
      assert result.success?
      assert_not result.data[:loaded]
      assert_equal 1, RecommendationModel.count
      assert_equal 3, RecommendationItemNeighbor.count
    end

    test "a newer version retires the old one and removes its rows" do
      publish(@store, "2026-10-08")
      LoadModel.call(domain: :books, store: @store)
      publish(@store, "2026-10-09", rows: [[5, 6, 0.1]])
      result = LoadModel.call(domain: :books, store: @store)
      assert result.data[:loaded]
      assert_equal "2026-10-09", RecommendationModel.active_for(:books).version
      assert_nil RecommendationModel.find_by(version: "2026-10-08"), "retired models are deleted after the swap"
      assert_equal [[5, 6, 0.1]], RecommendationItemNeighbor.pluck(:item_id, :neighbor_id, :weight)
    end

    test "a row-count mismatch keeps the old model active and the new one loading" do
      publish(@store, "2026-10-08")
      LoadModel.call(domain: :books, store: @store)
      publish(@store, "2026-10-09", manifest_rows: 99)
      result = LoadModel.call(domain: :books, store: @store)
      assert_not result.success?
      assert_match(/99/, result.errors.first)
      assert_match(/3/, result.errors.first)
      assert_equal "2026-10-08", RecommendationModel.active_for(:books).version
      assert RecommendationModel.find_by(version: "2026-10-09").loading?
    end

    test "a stale loading row is reloaded cleanly" do
      publish(@store, "2026-10-09")
      stale = RecommendationModel.create!(domain: "books", version: "2026-10-09", state: :loading)
      stale.recommendation_item_neighbors.create!(item_id: 9, neighbor_id: 9, weight: 9.0)
      result = LoadModel.call(domain: :books, store: @store)
      assert result.data[:loaded]
      assert_equal 3, stale.reload.recommendation_item_neighbors.count
      assert stale.active?
    end

    test "an explicit version loads a hold-out model that latest does not point at" do
      publish(@store, "2026-10-09-holdout-42", latest: false)
      result = LoadModel.call(domain: :books, store: @store, version: "2026-10-09-holdout-42")
      assert result.data[:loaded]
      assert_equal "2026-10-09-holdout-42", RecommendationModel.active_for(:books).version
    end

    test "no published model is a quiet success" do
      result = LoadModel.call(domain: :books, store: @store)
      assert result.success?
      assert_not result.data[:loaded]
      assert_equal 0, RecommendationModel.count
    end
  end
end
