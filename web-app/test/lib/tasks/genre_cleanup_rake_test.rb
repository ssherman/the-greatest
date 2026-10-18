require "test_helper"
require "rake"

class GenreCleanupRakeTest < ActiveSupport::TestCase
  TASKS = %w[draft map split_check report retarget_worldcat apply].freeze
  GP = Services::Books::GenrePlan

  setup do
    unless Rake::Task.task_defined?("categories:genres:apply")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/genre_cleanup.rake").to_s }
    end
    TASKS.each { |name| Rake::Task["categories:genres:#{name}"].reenable }
    @missing = Rails.root.join("tmp", "missing_genre_plan_#{SecureRandom.hex(4)}.yml").to_s
    @assignments = @missing.sub(".yml", ".csv")
  end

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  def aborting(task)
    captured = +""
    capture_io do
      assert_raises(SystemExit) { Rake::Task["categories:genres:#{task}"].invoke }
    ensure
      captured << $stderr.string
    end
    captured
  end

  def stub_existing_plan
    GP::PlanFile.stubs(:load).returns(GP::PlanFile.new({"run" => "rk1"}, path: @missing))
  end

  def ok(klass, data) = klass::Result.new(success?: true, data: data, errors: [])

  def apply_result(rerun: false)
    ok(GP::Apply, applier: {"delete" => 2, "failed" => 0, "stale" => 0}, cleaned: {saved_searches: [11], recommendation_configs: [22]},
      unassigned_split_books: 4, rerun: rerun)
  end

  def run_apply(&block)
    with_env("PLAN" => @missing, "ASSIGNMENTS" => @assignments, &block)
  end

  test "apply with no plan file aborts and says so" do
    run_apply do
      assert_match(/no plan file/, aborting("apply"))
    end
  end

  test "apply prints the counts, cleaned ids and unassigned split books" do
    GP::Apply.stubs(:call).returns(apply_result)

    run_apply do
      out, = capture_io { Rake::Task["categories:genres:apply"].invoke }
      assert_match(/"delete" => 2/, out)
      assert_includes out, "[11]"
      assert_includes out, "[22]"
      assert_match(/split genres with no answer.*4/, out)
      refute_match(/already built/, out)
    end
  end

  test "apply aborts non-zero and lists failed decisions" do
    category = ::Books::Category.create!(name: "Broken Genre", category_type: :genre)
    CategoryCleanupDecision.create!(category: category, run: "rk1", stage: GP::DecisionBuilder::STAGE, action: :delete, decided_by: :ai,
      status: :failed, error: "boom")
    GP::PlanFile.stubs(:load).returns(GP::PlanFile.new({"run" => "rk1"}, path: @missing))
    GP::Apply.stubs(:call).returns(apply_result)

    run_apply do
      combined = +""
      capture_io do
        assert_raises(SystemExit) { Rake::Task["categories:genres:apply"].invoke }
      ensure
        combined << $stderr.string
      end
      assert_match(/failed/, combined)
      assert_includes combined, "Broken Genre"
      assert_includes combined, "boom"
      assert_match(/failed: fix the cause, reset the decision to proposed/, combined)
      refute_match(/stale:/, combined)
    end
  end

  test "apply aborts with the stale remedy for a stale decision" do
    category = ::Books::Category.create!(name: "Moved Genre", category_type: :genre)
    CategoryCleanupDecision.create!(category: category, run: "rk1", stage: GP::DecisionBuilder::STAGE, action: :delete, decided_by: :ai,
      status: :stale)
    stub_existing_plan
    GP::Apply.stubs(:call).returns(apply_result)

    run_apply do
      combined = aborting("apply")
      assert_includes combined, "Moved Genre"
      assert_match(/stale: the category changed after the plan was built.*status: :rejected/m, combined)
      refute_match(/failed: fix the cause/, combined)
    end
  end

  test "apply ignores failed decisions from other stages" do
    category = ::Books::Category.create!(name: "Other Stage", category_type: :genre)
    CategoryCleanupDecision.create!(category: category, run: "rk1", stage: "subjects_head", action: :delete, decided_by: :ai, status: :failed, error: "x")
    stub_existing_plan
    GP::Apply.stubs(:call).returns(apply_result)

    run_apply do
      out, = capture_io { Rake::Task["categories:genres:apply"].invoke }
      assert_match(/Applied:/, out)
    end
  end

  test "apply on a rerun explains the plan was already built" do
    GP::Apply.stubs(:call).returns(apply_result(rerun: true))

    run_apply do
      out, = capture_io { Rake::Task["categories:genres:apply"].invoke }
      assert_match(/already built/, out)
      assert_match(/new `run:` value/, out)
      assert_match(/not retried/, out)
      assert_match(/Stale decisions/, out)
      refute_match(/split genres with no answer \(given/, out)
    end
  end

  test "apply aborts with the service errors" do
    GP::Apply.stubs(:call).returns(GP::Apply::Result.new(success?: false, data: nil, errors: ["bad plan"]))

    run_apply do
      assert_match(/bad plan/, aborting("apply"))
    end
  end

  test "draft prints the genre count and notes" do
    GP::Draft.expects(:call).with(path: @missing, force: true).returns(ok(GP::Draft, genres: 12, notes: ["a note"]))

    with_env("PLAN" => @missing, "FORCE" => "1") do
      assert_output(/Drafted 12 genres.*a note/m) { Rake::Task["categories:genres:draft"].invoke }
    end
  end

  test "draft aborts when the service fails" do
    GP::Draft.stubs(:call).returns(GP::Draft::Result.new(success?: false, data: nil, errors: ["has decisions"]))

    with_env("PLAN" => @missing, "FORCE" => nil) do
      assert_match(/has decisions/, aborting("draft"))
    end
  end

  test "map prints the batch summary" do
    GP::Map.stubs(:call).returns(ok(GP::Map, mapped: 28, batches: 1, failed_batches: 0, remaining: 2))

    with_env("PLAN" => @missing) do
      assert_output(/Mapped 28 genres in 1 batches.*2 still unmapped.*again/m) { Rake::Task["categories:genres:map"].invoke }
    end
  end

  test "report prints the report lines and the validation result" do
    GP::Report.stubs(:call).returns(ok(GP::Report, lines: ["== keep (1)"]))
    GP::Validator.stubs(:call).returns(ok(GP::Validator, nil))

    with_env("PLAN" => @missing, "ASSIGNMENTS" => @assignments) do
      assert_output(/== keep \(1\).*The plan passes every check\./m) { Rake::Task["categories:genres:report"].invoke }
    end
  end

  test "report lists the problems" do
    GP::Report.stubs(:call).returns(ok(GP::Report, lines: []))
    GP::Validator.stubs(:call).returns(GP::Validator::Result.new(success?: false, data: nil, errors: ["unknown target"]))

    with_env("PLAN" => @missing, "ASSIGNMENTS" => @assignments) do
      assert_output(/Problems:\nunknown target/) { Rake::Task["categories:genres:report"].invoke }
    end
  end

  test "split_check aborts when there is no plan file" do
    with_env("PLAN" => @missing, "ASSIGNMENTS" => @assignments) do
      assert_match(/no plan file/, aborting("split_check"))
    end
  end

  test "split_check prints the estimate before calling" do
    stub_existing_plan
    GP::SplitCheck.stubs(:calls_needed).returns(3)
    GP::SplitCheck.stubs(:call).returns(ok(GP::SplitCheck, checked: 30, calls: 3, failed_calls: 0))

    with_env("PLAN" => @missing, "ASSIGNMENTS" => @assignments) do
      assert_output(/split_check: 3 calls.*Checked 30 books in 3 calls/m) { Rake::Task["categories:genres:split_check"].invoke }
    end
  end

  test "split_check aborts when the cost guard trips" do
    stub_existing_plan
    GP::SplitCheck.stubs(:calls_needed).returns(99_999)
    GP::SplitCheck.stubs(:call).raises(Services::CategoryCleanup::CostGuard::TooExpensive, "too much")

    with_env("PLAN" => @missing, "ASSIGNMENTS" => @assignments) do
      assert_match(/too much/, aborting("split_check"))
    end
  end

  test "retarget_worldcat prints the count and the split-terms note" do
    GP::RetargetWorldCat.stubs(:call).returns(ok(GP::RetargetWorldCat, retargeted: 7))

    with_env("PLAN" => @missing) do
      out, = capture_io { Rake::Task["categories:genres:retarget_worldcat"].invoke }
      assert_match(/Retargeted 7/, out)
      assert_match(/restore config\/worldcat\/genre_map\.yml from git/, out)
    end
  end

  test "retarget_worldcat aborts with the service errors" do
    GP::RetargetWorldCat.stubs(:call).returns(GP::RetargetWorldCat::Result.new(success?: false, data: nil, errors: ["bad term"]))

    with_env("PLAN" => @missing) do
      assert_match(/bad term/, aborting("retarget_worldcat"))
    end
  end
end
