# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksGoodreadsReimportRakeTest < ActiveSupport::TestCase
  JOBS = Books::GoodreadsReimport

  setup do
    unless Rake::Task.task_defined?("books:goodreads_reimport:report")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/goodreads_reimport.rake").to_s }
    end
    Rake::Task.tasks.each(&:reenable)
    @config = Rails.configuration.x.goodreads_reimport
    @was = @config.enabled
  end

  teardown { @config.enabled = @was }

  def run_task(name, *args) = capture_io { Rake::Task["books:goodreads_reimport:#{name}"].invoke(*args) }.first

  test "gated tasks abort while the gate is off" do
    @config.enabled = false
    JOBS::MatchEditionsJob.expects(:enqueue).never
    JOBS::ApplyJob.expects(:perform_async).never

    %w[archive_mixed match decide apply check_authors].each do |name|
      Rake::Task["books:goodreads_reimport:#{name}"].reenable
      assert_raises(SystemExit) { capture_io { Rake::Task["books:goodreads_reimport:#{name}"].invoke("all") } }
    end
  end

  test "archive_mixed reminds about the survey and queues the archive" do
    @config.enabled = true
    JOBS::ArchiveMixedJob.expects(:enqueue).returns(12)

    out = run_task("archive_mixed")

    assert_match(/books:goodreads_rebuild:survey\[all,redo\]/, out)
    assert_match(/queued the archive of 12 mixed books/, out)
  end

  test "match passes the limit" do
    @config.enabled = true
    JOBS::MatchEditionsJob.expects(:enqueue).with(limit: 50).returns(50)
    assert_match(/queued 50 editions/, run_task("match", "50"))

    Rake::Task["books:goodreads_reimport:match"].reenable
    JOBS::MatchEditionsJob.expects(:enqueue).with(limit: nil).returns(9)
    assert_match(/queued 9 editions/, run_task("match", "all"))
  end

  test "a bad limit aborts" do
    @config.enabled = true
    assert_raises(SystemExit) { capture_io { Rake::Task["books:goodreads_reimport:decide"].invoke("bogus") } }
  end

  test "decide queues the row decisions and the guesses" do
    @config.enabled = true
    JOBS::DecideRowsJob.expects(:enqueue).with(limit: nil).returns(4)
    JOBS::DecideGuessesJob.expects(:enqueue).returns(2)

    out = run_task("decide", "all")

    assert_match(/queued 4 users/, out)
    assert_match(/queued 2 mixed books for guesses/, out)
  end

  test "apply starts one chain" do
    @config.enabled = true
    JOBS::ApplyJob.expects(:perform_async).with

    assert_match(/queued the apply chain/, run_task("apply"))
  end

  test "check_authors passes the limit" do
    @config.enabled = true
    JOBS::CheckAuthorsJob.expects(:enqueue).with(limit: 3).returns(3)

    assert_match(/queued 3 books/, run_task("check_authors", "3"))
  end

  test "report prints with the gate off" do
    @config.enabled = false
    Services::Books::GoodreadsReimport::Report.expects(:call).returns("THE REPORT")

    assert_match(/THE REPORT/, run_task("report"))
  end

  test "snapshot prints the user count and runs inline" do
    @config.enabled = false
    Services::Books::GoodreadsReimport::Report.expects(:snapshot).returns(812)

    assert_match(/counts of 812 users/, run_task("snapshot"))
  end

  test "sample only enqueues the job, even with the gate off" do
    @config.enabled = false
    JOBS::SampleJob.expects(:perform_async)
    Services::Books::GoodreadsReimport::Report.expects(:sample).never

    assert_match(/queued the sample check/, run_task("sample"))
  end
end
