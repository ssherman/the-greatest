require "test_helper"

class Services::BooksMigration::ListPenaltyMigratorTest < ActiveSupport::TestCase
  setup do
    @list = Books::List.create!(name: "LP List")
    @static_penalty = Global::Penalty.create!(name: "Voters: not critics, authors, or experts")
    @dynamic_penalty = Global::Penalty.create!(name: "Voters: Voter Count", dynamic_type: :number_of_voters)
    LegacyIdMap.record(model: "Penalty", legacy_id: 500, new_id: @static_penalty.id)
    LegacyIdMap.record(model: "Penalty", legacy_id: 501, new_id: @dynamic_penalty.id)
  end

  def run_migrator(rows)
    m = Services::BooksMigration::ListPenaltyMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def lcl(id, overrides = {})
    {
      "id" => id,
      "list_con_id" => 500,
      "list_id" => @list.id,
      "created_at" => Time.utc(2020, 1, 2, 3, 4, 5),
      "updated_at" => Time.utc(2021, 2, 3, 4, 5, 6)
    }.merge(overrides)
  end

  test "creates a list_penalty for a static-target list_con_list" do
    result = run_migrator([lcl(1)])
    assert result[:success], result[:error]
    lp = ListPenalty.find_by(list_id: @list.id, penalty_id: @static_penalty.id)
    assert_not_nil lp
    assert_equal Time.utc(2020, 1, 2, 3, 4, 5), lp.created_at
  end

  test "skips a dynamic-target list_con_list" do
    assert_no_difference -> { ListPenalty.count } do
      run_migrator([lcl(2, "list_con_id" => 501)])
    end
  end

  test "dedups repeated [list_id, penalty_id] pairs" do
    assert_difference -> { ListPenalty.count }, 1 do
      run_migrator([lcl(3), lcl(4)])
    end
  end

  test "fails loud when the list is not a migrated Books::List" do
    missing = List.maximum(:id).to_i + 999_999
    result = run_migrator([lcl(5, "list_id" => missing)])
    refute result[:success]
    assert_match(/list_con_list id=5/, result[:error])
  end

  test "is idempotent on [list_id, penalty_id]" do
    run_migrator([lcl(6)])
    assert_no_difference -> { ListPenalty.count } do
      run_migrator([lcl(6)])
    end
  end

  test "fails loud when no penalties have been migrated" do
    LegacyIdMap.where(model: "Penalty").delete_all
    result = run_migrator([lcl(7)])
    refute result[:success]
    assert_match(/penalt/i, result[:error])
  end
end
