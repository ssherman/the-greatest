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

  test "verify_unverified queues the sweep, with a limit when one is given" do
    task = Rake::Task["books:goodreads:verify_unverified"]
    Books::Goodreads::VerifyUnverifiedJob.expects(:perform_async).with
    Books::Goodreads::VerifyUnverifiedJob.expects(:perform_async).with(50)

    assert_output(/queued Books::Goodreads::VerifyUnverifiedJob/) { task.invoke }
    task.reenable
    assert_output(/limit 50/) { task.invoke("50") }
  ensure
    task&.reenable
  end

  test "seed_legacy_pages prints what it loaded" do
    seed = Services::Books::GoodreadsPages::SeedLegacyPages
    seed.expects(:call).returns(seed::Result.new(success?: true, data: {inserted: 3, already_present: 1, skipped: 2}, errors: []))

    assert_output(/inserted 3, already present 1, skipped 2/) { Rake::Task["books:goodreads:seed_legacy_pages"].invoke }
  ensure
    Rake::Task["books:goodreads:seed_legacy_pages"].reenable
  end
end
