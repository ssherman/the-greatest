require "test_helper"

class Services::BooksMigration::NumYearsCoveredMigratorTest < ActiveSupport::TestCase
  ONE_YEAR = "List: only covers 1 year (yearly book awards, best of the year, etc)"

  setup do
    @list = ::Books::List.create!(name: "Years List")
    # The migrator calls NumYearsCoveredFile.load with no arguments; tests never
    # touch the real config file.
    Services::BooksMigration::NumYearsCoveredFile.stubs(:load).with.returns({})
  end

  def overrides(hash)
    Services::BooksMigration::NumYearsCoveredFile.stubs(:load).with.returns(hash)
  end

  def run_migrator(rows)
    m = Services::BooksMigration::NumYearsCoveredMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def row(id, overrides = {})
    {
      "id" => id,
      "list_id" => @list.id,
      "list_con_name" => "List: only covers 25 years",
      "ranking_configuration_id" => 68
    }.merge(overrides)
  end

  test "sets the legacy bucket when there is no override" do
    result = run_migrator([row(1)])
    assert result[:success], result[:error]
    assert_equal 25, @list.reload.num_years_covered
    assert_equal 1, result[:data][:lists_updated]
    assert_equal 0, result[:data][:overrides_applied]
  end

  test "an override beats the bucket" do
    overrides(@list.id => 21)
    result = run_migrator([row(1)])
    assert result[:success], result[:error]
    assert_equal 21, @list.reload.num_years_covered
    assert_equal 1, result[:data][:overrides_applied]
  end

  test "the one-year bucket maps to 1" do
    run_migrator([row(1, "list_con_name" => ONE_YEAR)])
    assert_equal 1, @list.reload.num_years_covered
  end

  test "the highest legacy ranking configuration wins a conflict, whatever the row order" do
    run_migrator([row(1, "ranking_configuration_id" => 68, "list_con_name" => "List: only covers 25 years"),
      row(2, "ranking_configuration_id" => 48, "list_con_name" => ONE_YEAR)])
    assert_equal 25, @list.reload.num_years_covered

    run_migrator([row(3, "ranking_configuration_id" => 48, "list_con_name" => ONE_YEAR),
      row(4, "ranking_configuration_id" => 68, "list_con_name" => "List: only covers 10 years")])
    assert_equal 10, @list.reload.num_years_covered
  end

  test "overwrites a stale value on re-run (idempotent)" do
    @list.update!(num_years_covered: 99)
    run_migrator([row(1)])
    assert_equal 25, @list.reload.num_years_covered
    run_migrator([row(1)])
    assert_equal 25, @list.reload.num_years_covered
  end

  test "leaves a list with no year-span row untouched" do
    other = ::Books::List.create!(name: "All time", num_years_covered: 137)
    run_migrator([row(1)])
    assert_equal 137, other.reload.num_years_covered
  end

  test "reports override ids that match no list without failing" do
    ghost = List.maximum(:id).to_i + 999_999
    overrides(ghost => 5)
    result = run_migrator([row(1)])
    assert result[:success], result[:error]
    assert_equal [ghost], result[:data][:unknown_override_ids]
    assert_equal 25, @list.reload.num_years_covered
  end

  test "skips a row belonging to a superseded users' favorites list" do
    missing = List.maximum(:id).to_i + 999_999
    Services::BooksMigration::ListMigrator.stubs(:superseded_legacy_list_ids).returns(Set[missing])
    result = run_migrator([row(1, "list_id" => missing)])
    assert result[:success], result[:error]
    assert_equal 0, result[:data][:lists_updated]
  end

  test "fails loud when the parent list is missing for any other reason" do
    missing = List.maximum(:id).to_i + 999_999
    result = run_migrator([row(9, "list_id" => missing)])
    refute result[:success]
    assert_match(/#{missing}/, result[:error])
  end

  test "fails loud on an unknown year-span name" do
    result = run_migrator([row(1, "list_con_name" => "List: only covers 12 years")])
    refute result[:success]
    assert_match(/12 years/, result[:error])
  end

  test "fails loud when no Books::List has been migrated at all" do
    ::Books::List.stubs(:exists?).returns(false)
    result = run_migrator([row(1)])
    refute result[:success]
    assert_match(/data_migration:lists/, result[:error])
  end

  test "surfaces a malformed override file as a failure" do
    Services::BooksMigration::NumYearsCoveredFile.stubs(:load).with.raises(ArgumentError, "entry 5: 0 is not a positive integer")
    result = run_migrator([row(1)])
    refute result[:success]
    assert_match(/not a positive integer/, result[:error])
  end
end
