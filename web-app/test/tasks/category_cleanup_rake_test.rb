require "test_helper"
require "rake"

class CategoryCleanupRakeTest < ActiveSupport::TestCase
  PROPOSE = "categories:cleanup:propose"

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?(PROPOSE)
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

  test "reject marks the given decisions rejected" do
    decision = CategoryCleanupDecision.create!(category: categories(:books_france_location), run: "t1", stage: "rules", action: :keep, decided_by: :rule)

    capture_io { Rake::Task["categories:cleanup:reject"].invoke("t1", decision.id.to_s) }

    assert decision.reload.rejected?
  end
end
