require "test_helper"
require "rake"

class DataMigrationRakeTaskTest < ActiveSupport::TestCase
  VerificationResult = Data.define(:success?, :data, :errors)

  setup do
    unless Rake::Task.task_defined?("data_migration:reading_goals")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      load Rails.root.join("lib/tasks/data_migration.rake").to_s
    end
    %w[
      data_migration:reading_goals
      data_migration:verify_reading_goals
      data_migration:num_years_covered:derive
      data_migration:list_penalties
      data_migration:all
    ].each { |name| Rake::Task[name].reenable if Rake::Task.task_defined?(name) }
  end

  test "reading goals run immediately after user-list items in the all task" do
    prerequisites = Rake::Task["data_migration:all"].prerequisites

    reading_goal_index = prerequisites.index("reading_goals")
    assert_equal prerequisites.index("user_list_items") + 1, reading_goal_index
    assert_operator reading_goal_index, :<, prerequisites.index("saved_searches")
    assert_operator reading_goal_index, :<, prerequisites.index("reviews")
  end

  test "reading_goals invokes the migrator" do
    Services::BooksMigration::ReadingGoalMigrator.expects(:call).once.returns(
      success: true,
      data: {model: "Books::ReadingGoal", count: 399}
    )

    capture_io { Rake::Task["data_migration:reading_goals"].invoke }
  end

  test "reading_goals aborts when migration fails" do
    Services::BooksMigration::ReadingGoalMigrator.stubs(:call).returns(
      success: false,
      error: "reserved id collision"
    )

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:reading_goals"].invoke }
    end
    assert_match(/reading_goals migration failed: reserved id collision/, err)
  end

  test "verify_reading_goals prints successful verification data" do
    Services::BooksMigration::ReadingGoalVerification.expects(:call).once.returns(
      VerificationResult.new(success?: true, data: {imported_goals: 399}, errors: [])
    )

    out, _err = capture_io { Rake::Task["data_migration:verify_reading_goals"].invoke }

    assert_match(/imported_goals/, out)
    assert_match(/399/, out)
  end

  test "verify_reading_goals aborts with joined errors" do
    Services::BooksMigration::ReadingGoalVerification.stubs(:call).returns(
      VerificationResult.new(
        success?: false,
        data: {},
        errors: ["wrong goal count", "unexpected target schema"]
      )
    )

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:verify_reading_goals"].invoke }
    end
    assert_match(/reading_goals verification failed: wrong goal count; unexpected target schema/, err)
  end

  test "num_years_covered:derive derives from legacy rows and appends to the review file" do
    rows = [{id: 7, name: "Best of the 1990s", description: nil, year_published: 2001, bucket: 10, buckets: [10]}]
    Services::BooksMigration::NumYearsCoveredDeriver.expects(:legacy_rows).once.returns(rows)
    Services::BooksMigration::NumYearsCoveredFile.expects(:append).once.with { |entries|
      entries.size == 1 && entries.first.id == 7 && entries.first.years == 10
    }.returns(kept: 3, added: 1)

    out, _err = capture_io { Rake::Task["data_migration:num_years_covered:derive"].invoke }
    assert_match(/kept 3 existing entries, added 1/, out)
  end

  test "list_penalties runs the num_years_covered migrator after the list-penalty migrator" do
    order = sequence("list_penalties")
    Services::BooksMigration::ListPenaltyMigrator.expects(:call).once.in_sequence(order)
      .returns(success: true, data: {model: "ListPenalty", count: 1})
    Services::BooksMigration::NumYearsCoveredMigrator.expects(:call).once.in_sequence(order)
      .returns(success: true, data: {model: "Books::List#num_years_covered", count: 1})

    capture_io { Rake::Task["data_migration:list_penalties"].invoke }
  end

  test "list_penalties aborts when the num_years_covered migrator fails" do
    Services::BooksMigration::ListPenaltyMigrator.stubs(:call).returns(success: true, data: {model: "ListPenalty", count: 1})
    Services::BooksMigration::NumYearsCoveredMigrator.stubs(:call).returns(success: false, error: "entry 5: 0 is not a positive integer")

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:list_penalties"].invoke }
    end
    assert_match(/num_years_covered migration failed: entry 5/, err)
  end
end
