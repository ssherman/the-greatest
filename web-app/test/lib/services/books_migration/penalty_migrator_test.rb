require "test_helper"

class Services::BooksMigration::PenaltyMigratorTest < ActiveSupport::TestCase
  MODEL_KEY = "Penalty"

  # NOTE: test/fixtures/penalties.yml already loads a Global::Penalty with
  # dynamic_type 0 (number_of_voters) and a Books::Penalty with dynamic_type 1
  # (percentage_western). Pick dynamic_type 2 here so the resolver's
  # globals_by_dynamic_type lookup is unambiguous (no fixture uses type 2).
  setup do
    @voter_names = Global::Penalty.create!(name: "Voters: Unknown Names", dynamic_type: :voter_names_unknown)
    @not_critics = Global::Penalty.create!(name: "Voters: not critics, authors, or experts")
    LegacyIdMap.record(model: "Books::RankingConfiguration", legacy_id: 48, new_id: 999_048)
  end

  def run_migrator(rows)
    m = Services::BooksMigration::PenaltyMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy(id, overrides = {})
    {
      "id" => id,
      "name" => "List: only covers 75 years",
      "points" => 20,
      "description" => "legacy desc #{id}",
      "ranking_configuration_id" => 48,
      "dynamic" => false,
      "dynamic_type" => nil,
      "created_at" => Time.utc(2020, 1, 2, 3, 4, 5),
      "updated_at" => Time.utc(2021, 2, 3, 4, 5, 6)
    }.merge(overrides)
  end

  def mapped(legacy_id)
    Penalty.find(LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: legacy_id))
  end

  test "creates a Books::Penalty for an unmatched static list_con, verbatim name + preserved fields" do
    assert_difference -> { Books::Penalty.count }, 1 do
      result = run_migrator([legacy(8001)])
      assert result[:success], result[:error]
    end
    penalty = mapped(8001)
    assert_equal "Books::Penalty", penalty.type
    assert_equal "List: only covers 75 years", penalty.name
    assert_nil penalty.dynamic_type
    assert_nil penalty.user_id
    assert_equal "legacy desc 8001", penalty.description
    assert_equal Time.utc(2020, 1, 2, 3, 4, 5), penalty.created_at
  end

  test "reuses an existing Global::Penalty by exact static name without creating or mutating it" do
    assert_no_difference -> { Penalty.count } do
      run_migrator([legacy(8002, "name" => "Voters: not critics, authors, or experts")])
    end
    assert_equal @not_critics.id, LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8002)
  end

  test "reuses the voter_names_unknown global for a dynamic_type 2 list_con" do
    run_migrator([legacy(8003, "name" => "Voters: Unknown Names", "dynamic_type" => 2)])
    assert_equal @voter_names.id, LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8003)
  end

  test "does not reuse a user-owned Global::Penalty; creates a system Books::Penalty instead" do
    user_global = Global::Penalty.create!(name: "List: honorable mention", user_id: users(:regular_user).id)
    assert_difference -> { Books::Penalty.count }, 1 do
      run_migrator([legacy(8009, "name" => "List: honorable mention")])
    end
    penalty = mapped(8009)
    assert_equal "Books::Penalty", penalty.type
    assert_not_equal user_global.id, penalty.id
    assert_nil penalty.user_id
  end

  test "creates the percentage_western Books::Penalty for dynamic_type 1" do
    run_migrator([legacy(8004, "name" => 'List: only covers mostly "Western Canon" books', "dynamic_type" => 1)])
    penalty = mapped(8004)
    assert_equal "Books::Penalty", penalty.type
    assert_equal "percentage_western", penalty.dynamic_type
  end

  test "records the map for every active-RC list_con" do
    run_migrator([legacy(8005), legacy(8006, "name" => "List: honorable mention")])
    assert_not_nil LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8005)
    assert_not_nil LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8006)
  end

  test "is idempotent: re-running reuses the same Books::Penalty and keeps the map" do
    run_migrator([legacy(8007)])
    first = LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8007)
    assert_no_difference -> { Penalty.count } do
      run_migrator([legacy(8007)])
    end
    assert_equal first, LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8007)
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([legacy(8008)])
    end
  end

  test "fails loud when no ranking configuration has been migrated" do
    LegacyIdMap.where(model: "Books::RankingConfiguration").delete_all
    result = Services::BooksMigration::PenaltyMigrator.new.call
    refute result[:success]
    assert_match(/ranking_configuration/, result[:error])
  end
end
