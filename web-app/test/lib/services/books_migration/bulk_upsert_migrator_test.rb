require "test_helper"

class Services::BooksMigration::BulkUpsertMigratorTest < ActiveSupport::TestCase
  # Minimal concrete subclass over the real category_items table: one legacy row ->
  # one category_item; book_id nil -> [] (skip); book_id "boom" -> raises. upsert_batch
  # is shrunk to 2 to force a flush mid-stream plus a final flush.
  class TestJoinMigrator < Services::BooksMigration::BulkUpsertMigrator
    def initialize(category_id)
      @category_id = category_id
    end

    private

    def legacy_model
      raise "legacy_each is stubbed in tests"
    end

    def model_key
      "TestJoin"
    end

    def target_model
      CategoryItem
    end

    def unique_by
      :index_category_items_on_category_id_and_item_type_and_item_id
    end

    def upsert_batch
      2
    end

    def build_rows(attrs)
      raise "boom row" if attrs["book_id"] == "boom"
      return [] if attrs["book_id"].nil?
      [{category_id: @category_id, item_type: "Books::Book", item_id: attrs["book_id"]}]
    end
  end

  def setup
    @category = Books::Category.create!(name: "Bulk Base Cat")
  end

  def run_migrator(rows)
    m = TestJoinMigrator.new(@category.id)
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "bulk-inserts every mapped row, flushing across the batch boundary" do
    result = run_migrator([
      {"id" => 1, "book_id" => 101},
      {"id" => 2, "book_id" => 102},
      {"id" => 3, "book_id" => 103}
    ])
    assert result[:success], result[:error]
    assert_equal 3, result[:data][:count]
    assert_equal [101, 102, 103], CategoryItem.where(category_id: @category.id).order(:item_id).pluck(:item_id)
  end

  test "build_rows returning [] contributes no rows" do
    result = run_migrator([{"id" => 1, "book_id" => nil}, {"id" => 2, "book_id" => 200}])
    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal [200], CategoryItem.where(category_id: @category.id).pluck(:item_id)
  end

  test "is idempotent on the target unique key" do
    rows = [{"id" => 1, "book_id" => 301}, {"id" => 2, "book_id" => 302}]
    run_migrator(rows)
    assert_no_difference -> { CategoryItem.count } do
      run_migrator(rows)
    end
  end

  test "reports per-row error context with the legacy id and returns success: false" do
    result = run_migrator([{"id" => 42, "book_id" => "boom"}])
    assert_not result[:success]
    assert_match "legacy id=42", result[:error]
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 1, "book_id" => 401}])
    end
  end
end
