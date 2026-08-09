# frozen_string_literal: true

require "test_helper"

class Services::BooksMigration::SavedSearchMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::SavedSearchMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # The legacy column is jsonb holding a JSON *string*, so the migrator receives
  # a String here -- reproducing that exactly is the point of this helper.
  def legacy_row(criteria_hash = {"genre_match_mode" => "any"}, overrides = {})
    {
      "id" => 900_001,
      "user_id" => users(:regular_user).id,
      "name" => "Migrated Search",
      "description" => "From legacy",
      "criteria" => criteria_hash.to_json,
      "public" => true,
      "last_executed_at" => Time.zone.parse("2026-03-01 12:00:00"),
      "result_count" => 77,
      "created_at" => Time.zone.parse("2025-01-01 00:00:00"),
      "updated_at" => Time.zone.parse("2026-03-01 12:00:00")
    }.merge(overrides)
  end

  setup do
    @category = ::Books::Category.create!(name: "Migrator Target Genre", category_type: :genre)
    LegacyIdMap.record(model: "Books::Category", legacy_id: 55_555, new_id: @category.id)
  end

  test "creates a Books::SavedSearch preserving the legacy id" do
    result = run_migrator([legacy_row])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]

    search = SavedSearch.find(900_001)
    assert_instance_of ::Books::SavedSearch, search
    assert_equal "Migrated Search", search.name
    assert_equal 77, search.result_count
    assert search.public?
  end

  test "unwraps the double-encoded criteria into a real hash" do
    run_migrator([legacy_row({"genre_match_mode" => "any", "ranked" => "true"})])

    criteria = SavedSearch.find(900_001).criteria
    assert_kind_of Hash, criteria
    assert_equal "true", criteria["ranked"]
  end

  test "the stored criteria is queryable as jsonb, not a string" do
    # The regression that matters: a string-stored criteria silently matches
    # nothing here while looking fine in a Ruby-level assertion.
    run_migrator([legacy_row({"genre_match_mode" => "any", "ranked" => "true"})])

    assert_equal 1, SavedSearch.where("criteria->>'ranked' = ?", "true").count
  end

  test "remaps category ids through LegacyIdMap" do
    run_migrator([legacy_row({"included_category_ids" => ["55555"]})])

    assert_equal [@category.id], SavedSearch.find(900_001).criteria["included_category_ids"]
  end

  test "remaps excluded category ids too" do
    run_migrator([legacy_row({"excluded_category_ids" => ["55555"]})])

    assert_equal [@category.id], SavedSearch.find(900_001).criteria["excluded_category_ids"]
  end

  test "leaves language and country ids untouched, only normalizing to integers" do
    run_migrator([legacy_row({
      "included_language_ids" => ["12"],
      "excluded_country_ids" => ["7"]
    })])

    criteria = SavedSearch.find(900_001).criteria
    assert_equal [12], criteria["included_language_ids"]
    assert_equal [7], criteria["excluded_country_ids"]
  end

  test "drops blank entries before normalizing passthrough ids to integers" do
    run_migrator([legacy_row({"included_language_ids" => ["12", ""]})])

    assert_equal [12], SavedSearch.find(900_001).criteria["included_language_ids"]
  end

  test "copies scalar criteria verbatim" do
    run_migrator([legacy_row({
      "book_type" => 0,
      "max_ranked_position" => 100,
      "ranked" => "false",
      "hide_read" => true,
      "genre_match_mode" => "all"
    })])

    criteria = SavedSearch.find(900_001).criteria
    assert_equal 0, criteria["book_type"]
    assert_equal 100, criteria["max_ranked_position"]
    assert_equal "false", criteria["ranked"]
    assert_equal true, criteria["hide_read"]
    assert_equal "all", criteria["genre_match_mode"]
  end

  test "preserves the legacy timestamps" do
    run_migrator([legacy_row])

    search = SavedSearch.find(900_001)
    assert_equal Time.zone.parse("2025-01-01 00:00:00"), search.created_at
  end

  test "raises when a category id has no LegacyIdMap entry" do
    result = run_migrator([legacy_row({"included_category_ids" => ["99999999"]})])

    refute result[:success]
    assert_match(/LegacyIdMap/, result[:error])
  end

  test "raises when criteria is not a JSON object" do
    result = run_migrator([legacy_row.merge("criteria" => "\"just a string\"")])

    refute result[:success]
    assert_match(/criteria/i, result[:error])
  end

  test "is idempotent on id" do
    rows = [legacy_row]
    run_migrator(rows)
    result = run_migrator(rows)

    assert result[:success], result[:error]
    assert_equal 1, SavedSearch.where(id: 900_001).count
  end

  test "resets the primary key sequence past the migrated maximum" do
    run_migrator([legacy_row])

    fresh = ::Books::SavedSearch.create!(user: users(:regular_user), criteria: {"genre_match_mode" => "any"})
    assert fresh.id > 900_001, "expected a fresh id above the migrated max, got #{fresh.id}"
  end
end
