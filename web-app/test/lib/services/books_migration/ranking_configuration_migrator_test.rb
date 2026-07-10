require "test_helper"

class Services::BooksMigration::RankingConfigurationMigratorTest < ActiveSupport::TestCase
  MODEL_KEY = "Books::RankingConfiguration"

  def run_migrator(rows)
    m = Services::BooksMigration::RankingConfigurationMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy(id, overrides = {})
    {
      "id" => id,
      "name" => "RC #{id}",
      "description" => nil,
      "global" => true,
      "user_id" => 1,
      "primary" => false,
      "starting_score" => 200,
      "inherited_from_id" => nil,
      "inherit_list_cons" => true,
      "archived" => false,
      "published_at" => nil,
      "algorithm_version" => 4,
      "min_max_normalization" => false,
      "min_list_weight" => -50,
      "max_age_for_penalty" => 50,
      "max_penalty_percentage" => 80,
      "list_limit" => nil,
      "apply_list_dates_penalty" => true,
      "apply_global_age_penalty" => false,
      "list_cons_are_percentages" => true,
      "bonus_pool_percentage" => 3.0,
      "exponent" => 3.0,
      "primary_mapped_list_id" => nil,
      "secondary_mapped_list_id" => nil,
      "primary_mapped_list_cutoff_limit" => nil,
      "created_at" => Time.utc(2024, 12, 29, 17, 58, 25),
      "updated_at" => Time.utc(2026, 3, 21, 14, 57, 39)
    }.merge(overrides)
  end

  def find_new(legacy_id)
    RankingConfiguration.find(LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: legacy_id))
  end

  test "creates a Books::RankingConfiguration with a fresh id, records the map, applies renames" do
    result = run_migrator([legacy(9001, "inherit_list_cons" => false, "max_age_for_penalty" => 40, "max_penalty_percentage" => 70)])
    assert result[:success], result[:error]
    assert_not_nil LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 9001)
    rc = find_new(9001)
    assert_equal "Books::RankingConfiguration", rc.type
    assert_equal "RC 9001", rc.name
    assert_equal false, rc.inherit_penalties
    assert_equal 40, rc.max_list_dates_penalty_age
    assert_equal 70, rc.max_list_dates_penalty_percentage
    assert_equal false, rc.archived
  end

  test "drops user_id so a global config passes validation" do
    result = run_migrator([legacy(9002, "global" => true, "user_id" => 1)])
    assert result[:success], result[:error]
    rc = find_new(9002)
    assert rc.global
    assert_nil rc.user_id
  end

  test "nulls inherited_from_id even when the legacy row references a parent" do
    result = run_migrator([legacy(9003, "inherited_from_id" => 12345)])
    assert result[:success], result[:error]
    assert_nil find_new(9003).inherited_from_id
  end

  test "migrates the primary flag" do
    RankingConfiguration.where(type: MODEL_KEY, primary: true).update_all(primary: false)
    result = run_migrator([legacy(9004, "primary" => true)])
    assert result[:success], result[:error]
    assert find_new(9004).primary
  end

  test "sets the mapped list ids directly" do
    primary = Books::List.create!(name: "Primary Mapped")
    secondary = Books::List.create!(name: "Secondary Mapped")
    result = run_migrator([legacy(9005, "primary_mapped_list_id" => primary.id, "secondary_mapped_list_id" => secondary.id)])
    assert result[:success], result[:error]
    rc = find_new(9005)
    assert_equal primary.id, rc.primary_mapped_list_id
    assert_equal secondary.id, rc.secondary_mapped_list_id
  end

  test "preserves legacy timestamps on create" do
    run_migrator([legacy(9006)])
    rc = find_new(9006)
    assert_equal Time.utc(2024, 12, 29, 17, 58, 25), rc.created_at
    assert_equal Time.utc(2026, 3, 21, 14, 57, 39), rc.updated_at
  end

  test "is idempotent: re-running updates in place and keeps the map" do
    run_migrator([legacy(9007, "name" => "V1")])
    first_id = LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 9007)
    assert_no_difference -> { RankingConfiguration.count } do
      run_migrator([legacy(9007, "name" => "V2")])
    end
    assert_equal first_id, LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 9007)
    assert_equal "V2", RankingConfiguration.find(first_id).name
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([legacy(9008)])
    end
  end
end
