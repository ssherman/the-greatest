require "test_helper"
require "rake"

class CategoryCleanupRakeTest < ActiveSupport::TestCase
  PROPOSE = "categories:cleanup:propose"

  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?(PROPOSE)
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/category_cleanup.rake").to_s }
    end
    %w[propose reject apply report calibrate].each { |name| Rake::Task["categories:cleanup:#{name}"].reenable }
  end

  test "propose rules writes rule decisions" do
    place = ::Books::Category.create!(name: "Japan (", category_type: :location)
    CategoryItem.create!(category: place, item: books_books(:war_and_peace))

    assert_output(/Rules:/) { Rake::Task[PROPOSE].invoke("t1", "rules") }

    assert CategoryCleanupDecision.exists?(run: "t1", category: place)
  end

  test "an AI stage over the cost limit aborts without calling the AI" do
    Services::CategoryCleanup::AiPass.any_instance.stubs(:call_count).returns(1_000_000)
    Services::CategoryCleanup::AiPass.any_instance.expects(:call).never

    assert_raises(SystemExit) do
      capture_io { Rake::Task[PROPOSE].invoke("t1", "locations_head") }
    end
  end

  test "propose hands the AI pass a progress lambda that prints one summary line" do
    captured = nil
    pass = stub(call_count: 1, call: stub(data: {candidates: 3}))
    Services::CategoryCleanup::AiPass.stubs(:new).with { |**kwargs| captured = kwargs[:progress] }.returns(pass)

    capture_io { Rake::Task[PROPOSE].invoke("t1", "locations_head") }

    assert captured.respond_to?(:call)
    out, = capture_io { captured.call(calls: 100, decided: 90, failed_calls: 2, missing: 8, candidates: 500) }
    assert_equal 1, out.lines.size
    %w[100 90 2 8 500].each { |value| assert_includes out, value }
  end

  test "after a tail stage propose prints the undecided head-tier count for that type" do
    Rails.configuration.x.categories_cleanup.stubs(:head_min_links).returns(1)
    ::Books::Category.where(category_type: :location).update_all(deleted: true)
    place = ::Books::Category.create!(name: "Kilwa", category_type: :location)
    CategoryItem.create!(category: place, item: books_books(:war_and_peace))
    pass = stub(call_count: 1, call: stub(data: {candidates: 0}))
    Services::CategoryCleanup::AiPass.stubs(:new).returns(pass)

    out, = capture_io { Rake::Task[PROPOSE].invoke("t1", "locations_tail") }

    assert_match(/Undecided head-tier locations: 1/, out)
  end

  test "REDO deletes only proposed and failed rows of the named run and stage" do
    a = ::Books::Category.create!(name: "Aaa", category_type: :location)
    mk = ->(run, stage, status) {
      CategoryCleanupDecision.create!(category: a, run: run, stage: stage, action: :keep, decided_by: :ai, status: status,
        category_snapshot: CategoryCleanupDecision.snapshot_of(a))
    }
    gone = [mk.call("t1", "locations_head", :proposed), mk.call("t1", "locations_head", :failed)]
    kept = [mk.call("t1", "locations_head", :rejected), mk.call("t1", "locations_tail", :proposed), mk.call("t2", "locations_head", :proposed)]
    ENV["REDO"] = "1"
    pass = stub(call_count: 1, call: stub(data: {candidates: 0}))
    Services::CategoryCleanup::AiPass.stubs(:new).returns(pass)

    capture_io { Rake::Task[PROPOSE].invoke("t1", "locations_head") }

    assert_equal [], CategoryCleanupDecision.where(id: gone.map(&:id)).to_a
    assert_equal kept.map(&:id).sort, CategoryCleanupDecision.where(id: kept.map(&:id)).pluck(:id).sort
  ensure
    ENV.delete("REDO")
  end

  test "REDO over the cost limit leaves the existing proposals in place" do
    a = ::Books::Category.create!(name: "Aaa", category_type: :location)
    decision = CategoryCleanupDecision.create!(category: a, run: "t1", stage: "locations_head", action: :keep, decided_by: :ai,
      category_snapshot: CategoryCleanupDecision.snapshot_of(a))
    ENV["REDO"] = "1"
    Services::CategoryCleanup::AiPass.any_instance.stubs(:call_count).returns(1_000_000)
    Services::CategoryCleanup::AiPass.any_instance.expects(:call).never

    assert_raises(SystemExit) { capture_io { Rake::Task[PROPOSE].invoke("t1", "locations_head") } }

    assert CategoryCleanupDecision.exists?(decision.id)
  ensure
    ENV.delete("REDO")
  end

  test "calibrate aborts cleanly when over the cost limit" do
    Services::CategoryCleanup::CostGuard.stubs(:check!).raises(Services::CategoryCleanup::CostGuard::TooExpensive, "too much")
    Services::CategoryCleanup::Calibrator.expects(:call).never

    assert_raises(SystemExit) { capture_io { Rake::Task["categories:cleanup:calibrate"].invoke("t1", "location") } }
  end

  test "reject marks the given decisions rejected" do
    decision = CategoryCleanupDecision.create!(category: categories(:books_france_location), run: "t1", stage: "rules", action: :keep, decided_by: :rule)

    capture_io { Rake::Task["categories:cleanup:reject"].invoke("t1", decision.id.to_s) }

    assert decision.reload.rejected?
  end
end
