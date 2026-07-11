require "test_helper"

class Services::BooksMigration::PenaltyApplicationMigratorTest < ActiveSupport::TestCase
  setup do
    @rc = Books::RankingConfiguration.create!(name: "PA Config")
    @penalty = Global::Penalty.create!(name: "Voters: Unknown Count", dynamic_type: :voter_count_unknown)
    LegacyIdMap.record(model: "Books::RankingConfiguration", legacy_id: 52, new_id: @rc.id)
    LegacyIdMap.record(model: "Penalty", legacy_id: 700, new_id: @penalty.id)
    LegacyIdMap.record(model: "Penalty", legacy_id: 701, new_id: @penalty.id)
  end

  def run_migrator(rows)
    m = Services::BooksMigration::PenaltyApplicationMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy(id, overrides = {})
    {
      "id" => id,
      "points" => 30,
      "ranking_configuration_id" => 52,
      "created_at" => Time.utc(2020, 1, 2, 3, 4, 5),
      "updated_at" => Time.utc(2021, 2, 3, 4, 5, 6)
    }.merge(overrides)
  end

  test "creates a penalty_application mapping penalty + rc, value from points" do
    result = run_migrator([legacy(700)])
    assert result[:success], result[:error]
    pa = PenaltyApplication.find_by(penalty_id: @penalty.id, ranking_configuration_id: @rc.id)
    assert_equal 30, pa.value
    assert_equal Time.utc(2020, 1, 2, 3, 4, 5), pa.created_at
  end

  test "keeps the MAX points on a [penalty, rc] collision" do
    assert_difference -> { PenaltyApplication.count }, 1 do
      run_migrator([legacy(700, "points" => 5), legacy(701, "points" => 85)])
    end
    pa = PenaltyApplication.find_by(penalty_id: @penalty.id, ranking_configuration_id: @rc.id)
    assert_equal 85, pa.value
  end

  test "MAX is order-independent" do
    run_migrator([legacy(700, "points" => 85), legacy(701, "points" => 5)])
    assert_equal 85, PenaltyApplication.find_by(penalty_id: @penalty.id, ranking_configuration_id: @rc.id).value
  end

  test "is idempotent on [penalty_id, ranking_configuration_id]" do
    run_migrator([legacy(700, "points" => 40)])
    assert_no_difference -> { PenaltyApplication.count } do
      run_migrator([legacy(700, "points" => 40)])
    end
  end

  test "fails loud when the penalty map is empty" do
    LegacyIdMap.where(model: "Penalty").delete_all
    result = run_migrator([legacy(700)])
    refute result[:success]
    assert_match(/penalt/i, result[:error])
  end

  test "fails loud when the ranking configuration map is empty" do
    LegacyIdMap.where(model: "Books::RankingConfiguration").delete_all
    result = run_migrator([legacy(700)])
    refute result[:success]
    assert_match(/ranking_configuration/, result[:error])
  end
end
