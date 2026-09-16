require "test_helper"

class Services::BooksMigration::PenaltyReconcilerTest < ActiveSupport::TestCase
  R = Services::BooksMigration::PenaltyReconciler
  ZERO = {
    list_penalties_repointed: 0, list_penalties_dropped: 0,
    applications_repointed: 0, applications_merged: 0,
    dynamic_applications_upserted: 0, year_list_penalties_dropped: 0,
    num_years_covered_backfilled: 0,
    id_map_repointed: 0, penalties_destroyed: 0
  }.freeze

  setup do
    @rc = ranking_configurations(:books_global)
    @other_rc = ranking_configurations(:books_year_2025)
    @list_a = ::Books::List.create!(name: "A")
    @list_b = ::Books::List.create!(name: "B")
    @follow_up = penalties(:honorable_mention_penalty) # Global target, by its seed name
    @weird_global = Global::Penalty.create!(name: "List: only covers items with a weird criteria")
    @years_global = Global::Penalty.create!(name: "List: number of years covered", dynamic_type: :num_years_covered)
    # The fixture is a Books::Penalty named exactly like the one-year static, so the
    # reconciler would find it by name in every test. Remove it (nothing in the join
    # fixtures references it) and let each test create the sources it needs.
    penalties(:books_one_year_penalty).destroy!
  end

  ONE_YEAR = "List: only covers 1 year (yearly book awards, best of the year, etc)"

  def honorable_source
    ::Books::Penalty.create!(name: "List: honorable mention")
  end

  def weird_source
    ::Books::Penalty.create!(name: "List: only covers books with a weird criteria(books to help you survive the digital age, etc)")
  end

  def year_source(name)
    ::Books::Penalty.create!(name: name)
  end

  test "is a no-op with all-zero counts when nothing needs reconciling" do
    result = R.call
    assert result[:success], result[:error]
    assert_equal ZERO, result[:data]
  end

  test "repoints list_penalties and applications from the honorable-mention duplicate to the global" do
    source = honorable_source
    ListPenalty.create!(list: @list_a, penalty: source)
    PenaltyApplication.create!(penalty: source, ranking_configuration: @other_rc, value: 50)

    result = R.call

    assert result[:success], result[:error]
    assert ListPenalty.exists?(list: @list_a, penalty: @follow_up)
    assert_equal 50, PenaltyApplication.find_by(penalty: @follow_up, ranking_configuration: @other_rc).value
    assert_nil ::Books::Penalty.find_by(name: "List: honorable mention")
    assert_equal 1, result[:data][:list_penalties_repointed]
    assert_equal 1, result[:data][:applications_repointed]
    assert_equal 1, result[:data][:penalties_destroyed]
  end

  test "drops a colliding list_penalty and merges a colliding application at MAX" do
    source = weird_source
    ListPenalty.create!(list: @list_a, penalty: source)
    ListPenalty.create!(list: @list_a, penalty: @weird_global)
    PenaltyApplication.create!(penalty: source, ranking_configuration: @rc, value: 60)
    PenaltyApplication.create!(penalty: @weird_global, ranking_configuration: @rc, value: 40)

    result = R.call

    assert result[:success], result[:error]
    assert_equal 1, ListPenalty.where(list: @list_a).count
    assert_equal 60, PenaltyApplication.find_by(penalty: @weird_global, ranking_configuration: @rc).value
    assert_equal 1, result[:data][:list_penalties_dropped]
    assert_equal 1, result[:data][:applications_merged]
  end

  test "a colliding application keeps the larger existing value" do
    source = weird_source
    PenaltyApplication.create!(penalty: source, ranking_configuration: @rc, value: 20)
    PenaltyApplication.create!(penalty: @weird_global, ranking_configuration: @rc, value: 40)

    R.call

    assert_equal 40, PenaltyApplication.find_by(penalty: @weird_global, ranking_configuration: @rc).value
  end

  test "repoints the legacy id map for a merged duplicate" do
    source = honorable_source
    LegacyIdMap.record(model: "Penalty", legacy_id: 2804, new_id: source.id)

    result = R.call

    assert_equal @follow_up.id, LegacyIdMap.lookup(model: "Penalty", legacy_id: 2804)
    assert_equal 1, result[:data][:id_map_repointed]
  end

  test "gives every configuration that applied a year-span static the dynamic global at its own MAX" do
    one_year = year_source(ONE_YEAR)
    ten_years = year_source("List: only covers 10 years")
    PenaltyApplication.create!(penalty: one_year, ranking_configuration: @rc, value: 50)
    PenaltyApplication.create!(penalty: ten_years, ranking_configuration: @rc, value: 30)
    PenaltyApplication.create!(penalty: ten_years, ranking_configuration: @other_rc, value: 25)
    ListPenalty.create!(list: @list_a, penalty: one_year)
    ListPenalty.create!(list: @list_b, penalty: ten_years)
    LegacyIdMap.record(model: "Penalty", legacy_id: 2970, new_id: ten_years.id)

    result = R.call

    assert result[:success], result[:error]
    assert_equal 50, PenaltyApplication.find_by(penalty: @years_global, ranking_configuration: @rc).value
    assert_equal 25, PenaltyApplication.find_by(penalty: @years_global, ranking_configuration: @other_rc).value
    assert_nil ::Books::Penalty.find_by(name: "List: only covers 10 years")
    assert_nil ::Books::Penalty.find_by(name: ONE_YEAR)
    assert_empty ListPenalty.where(list: [@list_a, @list_b])
    assert_equal @years_global.id, LegacyIdMap.lookup(model: "Penalty", legacy_id: 2970)
    assert_equal 2, result[:data][:dynamic_applications_upserted]
    assert_equal 2, result[:data][:year_list_penalties_dropped]
    assert_equal 2, result[:data][:penalties_destroyed]
  end

  test "an existing dynamic application is raised to MAX, never lowered" do
    PenaltyApplication.create!(penalty: year_source(ONE_YEAR), ranking_configuration: @rc, value: 30)
    PenaltyApplication.create!(penalty: @years_global, ranking_configuration: @rc, value: 45)

    R.call

    assert_equal 45, PenaltyApplication.find_by(penalty: @years_global, ranking_configuration: @rc).value
  end

  test "backfills the legacy bucket onto a tagged list that has no num_years_covered before destroying the static" do
    ten_years = year_source("List: only covers 10 years")
    reviewed = ::Books::List.create!(name: "Reviewed", num_years_covered: 11)
    ListPenalty.create!(list: @list_a, penalty: ten_years)
    ListPenalty.create!(list: reviewed, penalty: ten_years)
    PenaltyApplication.create!(penalty: ten_years, ranking_configuration: @rc, value: 30)

    result = R.call

    assert result[:success], result[:error]
    assert_equal 10, @list_a.reload.num_years_covered
    assert_equal 11, reviewed.reload.num_years_covered, "a reviewed value is never overwritten"
    assert_equal 1, result[:data][:num_years_covered_backfilled]
  end

  test "ignores user-authored penalties that share a name" do
    user = users(:regular_user)
    mine = ::Books::Penalty.create!(name: "List: honorable mention", user: user)

    result = R.call

    assert ::Books::Penalty.exists?(mine.id)
    assert_equal ZERO, result[:data]
  end

  test "running twice leaves the database identical and reports zeros" do
    source = honorable_source
    ListPenalty.create!(list: @list_a, penalty: source)
    PenaltyApplication.create!(penalty: year_source(ONE_YEAR), ranking_configuration: @rc, value: 50)
    R.call
    snapshot = [Penalty.count, ListPenalty.count, PenaltyApplication.count,
      PenaltyApplication.order(:id).pluck(:penalty_id, :ranking_configuration_id, :value),
      LegacyIdMap.where(model: "Penalty").order(:legacy_id).pluck(:legacy_id, :new_id)]

    result = R.call

    assert_equal ZERO, result[:data]
    assert_equal snapshot, [Penalty.count, ListPenalty.count, PenaltyApplication.count,
      PenaltyApplication.order(:id).pluck(:penalty_id, :ranking_configuration_id, :value),
      LegacyIdMap.where(model: "Penalty").order(:legacy_id).pluck(:legacy_id, :new_id)]
  end

  test "fails loud when a year-span static exists but no num_years_covered global is seeded" do
    @years_global.destroy!
    one_year = year_source(ONE_YEAR)
    PenaltyApplication.create!(penalty: one_year, ranking_configuration: @rc, value: 50)

    result = R.call

    refute result[:success]
    assert_match(/num_years_covered/, result[:error])
    assert ::Books::Penalty.exists?(one_year.id), "the transaction must roll back"
  end

  test "a failed run reports zero counts, not the rolled-back partial work" do
    @years_global.destroy!
    source = honorable_source
    ListPenalty.create!(list: @list_a, penalty: source)
    PenaltyApplication.create!(penalty: year_source(ONE_YEAR), ranking_configuration: @rc, value: 50)

    result = R.call

    refute result[:success]
    assert_equal ZERO, result[:data]
    assert ListPenalty.exists?(list: @list_a, penalty: source), "the merge must have rolled back too"
  end

  # Only the legacy configuration can say which of two year-span tags wins
  # (NumYearsCoveredMigrator applies that rule); the reconciler must not guess.
  test "fails loud when a list with no num_years_covered is tagged by two year-span statics" do
    one_year = year_source(ONE_YEAR)
    ten_years = year_source("List: only covers 10 years")
    ListPenalty.create!(list: @list_a, penalty: one_year)
    ListPenalty.create!(list: @list_a, penalty: ten_years)

    result = R.call

    refute result[:success]
    assert_match(/data_migration:list_penalties/, result[:error])
    assert_match(/#{@list_a.id}/, result[:error])
    assert ::Books::Penalty.exists?(one_year.id), "the transaction must roll back"
    assert_nil @list_a.reload.num_years_covered
  end

  test "two year-span tags on a list that already has a value are not a conflict" do
    one_year = year_source(ONE_YEAR)
    ten_years = year_source("List: only covers 10 years")
    reviewed = ::Books::List.create!(name: "Reviewed", num_years_covered: 7)
    ListPenalty.create!(list: reviewed, penalty: one_year)
    ListPenalty.create!(list: reviewed, penalty: ten_years)

    result = R.call

    assert result[:success], result[:error]
    assert_equal 7, reviewed.reload.num_years_covered
    assert_equal 2, result[:data][:penalties_destroyed]
  end
end
