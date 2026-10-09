require "test_helper"
require "rake"

class DataMigrationRakeTaskTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

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
      data_migration:penalties
      data_migration:list_penalties
      data_migration:penalties:reconcile
      data_migration:all
      data_migration:refuse_after_sync_init
      data_migration:sync_init
      data_migration:books
      data_migration:languages
      data_migration:sync
      data_migration:sync_report
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

  # penalties:reconcile follows in `all` and destroys rows; a migrator failure
  # before it must stop the chain, not be printed and walked past.
  test "list_penalties aborts before the num_years_covered migrator when the list-penalty migrator fails" do
    Services::BooksMigration::ListPenaltyMigrator.stubs(:call).returns(success: false, error: "no migrated Books::List for legacy list_con_lists.list_id=9")
    Services::BooksMigration::NumYearsCoveredMigrator.expects(:call).never

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:list_penalties"].invoke }
    end
    assert_match(/list_penalties migration failed: no migrated Books::List/, err)
  end

  test "penalties aborts when the penalty migrator fails, before the application migrator" do
    Services::BooksMigration::PenaltyMigrator.stubs(:call).returns(success: false, error: "no migrated ranking_configurations")
    Services::BooksMigration::PenaltyApplicationMigrator.expects(:call).never

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:penalties"].invoke }
    end
    assert_match(/penalties migration failed \(Penalty\): no migrated ranking_configurations/, err)
  end

  test "penalties aborts when the application migrator fails" do
    Services::BooksMigration::PenaltyMigrator.stubs(:call).returns(success: true, data: {model: "Penalty", count: 1})
    Services::BooksMigration::PenaltyApplicationMigrator.stubs(:call).returns(success: false, error: "key not found: 42", data: {model: "PenaltyApplication", count: 0})

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:penalties"].invoke }
    end
    assert_match(/penalties migration failed \(PenaltyApplication\): key not found: 42/, err)
  end

  test "penalties:reconcile invokes the reconciler" do
    Services::BooksMigration::PenaltyReconciler.expects(:call).once.returns(success: true, data: {penalties_destroyed: 0})
    capture_io { Rake::Task["data_migration:penalties:reconcile"].invoke }
  end

  test "penalties:reconcile aborts when the reconciler fails" do
    Services::BooksMigration::PenaltyReconciler.stubs(:call).returns(success: false, error: "no num_years_covered Global::Penalty seeded")
    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:penalties:reconcile"].invoke }
    end
    assert_match(/penalties:reconcile failed: no num_years_covered/, err)
  end

  test "penalties:reconcile runs immediately after list_penalties in the all task" do
    prerequisites = Rake::Task["data_migration:all"].prerequisites
    assert_equal prerequisites.index("list_penalties") + 1, prerequisites.index("penalties:reconcile")
    assert_operator prerequisites.index("penalties"), :<, prerequisites.index("list_penalties")
  end

  test "all checks for sync watermarks before anything else" do
    assert_equal "refuse_after_sync_init", Rake::Task["data_migration:all"].prerequisites.first
  end

  test "all refuses once the sync watermarks exist" do
    # Rake looks up every prerequisite before running the first one, and this file
    # loads only data_migration.rake. Load the real task, never a stub: the
    # favorites rake test skips loading its file when the task is already defined.
    unless Rake::Task.task_defined?("user_favorites_lists:rebuild")
      load Rails.root.join("lib/tasks/lists/user_favorites.rake").to_s
    end
    init_watermarks(books: 1, authors: 1, book_identifiers: 1)
    Services::BooksMigration::LanguageMigrator.expects(:call).never

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:all"].invoke }
    end
    assert_match(/use data_migration:sync/, err)
  end

  test "a catalog task refuses on its own once the sync watermarks exist" do
    init_watermarks(books: 1, authors: 1, book_identifiers: 1)
    Services::BooksMigration::BookMigrator.expects(:call).never

    capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:books"].invoke }
    end
  end

  test "a catalog task runs normally before sync_init" do
    Services::BooksMigration::BookMigrator.expects(:call).once.returns(success: true, data: {model: "Books::Book", count: 0})

    capture_io { Rake::Task["data_migration:books"].invoke }
  end

  test "the user-data tasks are not guarded" do
    %w[users user_lists user_list_items reading_goals saved_searches recommendation_configs reviews corrections news_posts description_safety_net].each do |name|
      refute_includes Rake::Task["data_migration:#{name}"].prerequisites, "refuse_after_sync_init", name
    end
  end

  test "sync_init prints the watermarks" do
    Services::BooksMigration::SyncInit.expects(:call).returns(
      Services::BooksMigration::SyncInit::Result.new(success?: true, data: {"books" => 5}, errors: [])
    )

    out, _err = capture_io { Rake::Task["data_migration:sync_init"].invoke }

    assert_match(/"books" => 5/, out)
  end

  test "sync_init passes BOOK_IDENTIFIERS_FROM through as the identifier watermark" do
    Services::BooksMigration::SyncInit.expects(:call).with(book_identifiers: 80_000).returns(
      Services::BooksMigration::SyncInit::Result.new(success?: true, data: {}, errors: [])
    )

    with_env("BOOK_IDENTIFIERS_FROM", "80000") { capture_io { Rake::Task["data_migration:sync_init"].invoke } }
  end

  test "sync_init aborts when it refuses" do
    Services::BooksMigration::SyncInit.stubs(:call).returns(
      Services::BooksMigration::SyncInit::Result.new(success?: false, data: {}, errors: ["sync watermarks already exist"])
    )

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:sync_init"].invoke }
    end
    assert_match(/sync_init failed: sync watermarks already exist/, err)
  end

  def sync_result(success: true, errors: [])
    Services::BooksMigration::Sync::Result.new(success?: success, data: {plan: nil, steps: [], indexed: {}}, errors: errors)
  end

  def with_env(name, value)
    previous = ENV[name]
    ENV[name] = value
    yield
  ensure
    ENV[name] = previous
  end

  test "sync passes FINAL through as a boolean" do
    {"1" => true, "true" => true, "yes" => true, "0" => false, nil => false}.each do |value, final|
      Rake::Task["data_migration:sync"].reenable
      Services::BooksMigration::Sync.expects(:call).with(final: final).returns(sync_result)

      with_env("FINAL", value) { capture_io { Rake::Task["data_migration:sync"].invoke } }
    end
  end

  test "sync aborts when the run fails" do
    Services::BooksMigration::Sync.stubs(:call).returns(sync_result(success: false, errors: ["editions failed: boom"]))

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:sync"].invoke }
    end
    assert_match(/data_migration:sync failed: editions failed: boom/, err)
  end

  test "sync_report prints the plan and runs nothing" do
    Services::BooksMigration::Sync.expects(:call).never
    plan = mock("plan")
    Services::BooksMigration::SyncPlan.expects(:build).with(final: false).returns(plan)
    Services::BooksMigration::SyncReport.expects(:render).with(plan).returns("REPORT")

    out, _err = with_env("FINAL", nil) { capture_io { Rake::Task["data_migration:sync_report"].invoke } }

    assert_includes out, "REPORT"
  end
end
