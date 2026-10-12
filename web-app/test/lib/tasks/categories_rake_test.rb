require "test_helper"
require "rake"

class CategoriesRakeTest < ActiveSupport::TestCase
  TASK = "categories:trim_locations"

  setup do
    # Load only this rake file (see category_cleanup_rake_test.rb).
    unless Rake::Task.task_defined?(TASK)
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/categories.rake").to_s }
    end
    Rake::Task[TASK].reenable
    @book = books_books(:war_and_peace)
  end

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  test "a limit is required" do
    ::Services::Books::TrimLocations.expects(:candidate_ids).never

    assert_raises(SystemExit) { capture_io { Rake::Task[TASK].invoke } }
  end

  test "DRY_RUN passes dry_run: true and FORCE passes force: true to both calls" do
    ::Services::Books::TrimLocations.expects(:candidate_ids).with(limit: 5, force: true).returns([@book.id])
    ::Services::Books::TrimLocations.expects(:call).with(book: @book, dry_run: true, force: true)
      .returns(::Services::Books::TrimLocations::Result.new(success?: true, data: {kept: [], removed: [], reason: "r", dry_run: true}, errors: []))

    with_env("DRY_RUN" => "1", "FORCE" => "1") do
      assert_output(/War and Peace/) { Rake::Task[TASK].invoke("5") }
    end
  end

  test "defaults to a real, non-forced run" do
    ::Services::Books::TrimLocations.expects(:candidate_ids).with(limit: 5, force: false).returns([@book.id])
    ::Services::Books::TrimLocations.expects(:call).with(book: @book, dry_run: false, force: false)
      .returns(::Services::Books::TrimLocations::Result.new(success?: true, data: {skipped: "x"}, errors: []))

    with_env("DRY_RUN" => nil, "FORCE" => nil) do
      capture_io { Rake::Task[TASK].invoke("5") }
    end
  end
end
