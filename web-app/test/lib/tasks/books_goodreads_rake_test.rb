# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksGoodreadsRakeTest < ActiveSupport::TestCase
  DRY_RUN = Services::Books::GoodreadsImports::DryRun

  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:goodreads:resolve_file")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/goodreads.rake").to_s }
    end
    @task = Rake::Task["books:goodreads:resolve_file"]
    @task.reenable
    @path = file_fixture("goodreads/small_export.csv").to_s
  end

  test "aborts with usage when no path is given" do
    DRY_RUN.expects(:call).never

    assert_output(nil, /usage: books:goodreads:resolve_file/) { assert_raises(SystemExit) { @task.invoke } }
  end

  test "aborts on a file that does not exist" do
    DRY_RUN.expects(:call).never

    assert_output(nil, /no such file/) { assert_raises(SystemExit) { @task.invoke("/nonexistent/export.csv") } }
  end

  test "prints the dry run's report for the given user" do
    user = users(:editor_user)
    DRY_RUN.expects(:call).with(bytes: File.binread(@path), user: user)
      .returns(DRY_RUN::Result.new(success?: true, data: {report: "the report"}, errors: []))

    assert_output(/the report/) { @task.invoke(@path, user.id.to_s) }
  end

  test "aborts with the reason when the file is refused" do
    DRY_RUN.stubs(:call).returns(DRY_RUN::Result.new(success?: false, data: {}, errors: ["missing Goodreads export headers: Title"]))

    assert_output(nil, /missing Goodreads export headers/) { assert_raises(SystemExit) { @task.invoke(@path) } }
  end
end
