# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksAuthorsRakeTest < ActiveSupport::TestCase
  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:authors:enrich") && Rake::Task.task_defined?("books:authors:enrich_report")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/authors.rake").to_s }
    end
    @task = Rake::Task["books:authors:enrich"]
    @task.reenable
  end

  def result(**data)
    ::Services::Books::Authors::Backfill::Result.new(success?: true, errors: [],
      data: {wikidata: 2, viaf: 1, left_out: 0, wikidata_done_at: Time.utc(2026, 10, 2, 12)}.merge(data))
  end

  test "a limit is required: none, zero and junk abort without queuing anything" do
    ::Services::Books::Authors::Backfill.expects(:call).never

    ["", "0", "lots"].each do |limit|
      @task.reenable
      assert_raises(SystemExit) { capture_io { @task.invoke(limit) } }
    end
  end

  test "a number is the limit and all is every author" do
    ::Services::Books::Authors::Backfill.expects(:call).with(limit: 100).returns(result)
    ::Services::Books::Authors::Backfill.expects(:call).with(limit: nil).returns(result)

    assert_output(/Planned 2 author run\(s\) starting at the Wikidata step/) { @task.invoke("100") }
    @task.reenable
    assert_output(/books:authors:enrich_report\[/) { @task.invoke("all") }
  end

  test "the report needs a time, and prints the report's lines" do
    report = Rake::Task["books:authors:enrich_report"]
    ::Services::Books::Authors::BackfillReport.expects(:call).with(since: Time.utc(2026, 10, 2, 12))
      .returns(::Services::Books::Authors::BackfillReport::Result.new(success?: true, errors: [], data: {lines: ["one", "two"]}))

    report.reenable
    assert_raises(SystemExit) { capture_io { report.invoke("") } }
    report.reenable
    assert_output("one\ntwo\n") { report.invoke("2026-10-02T12:00:00Z") }
  end

  test "a bare number is not a time -- enrich's limit does not belong here" do
    report = Rake::Task["books:authors:enrich_report"]
    ::Services::Books::Authors::BackfillReport.expects(:call).never

    report.reenable
    assert_raises(SystemExit) { capture_io { report.invoke("100") } }
  end

  def merge_unknown_result(sources)
    ::Services::Books::Authors::MergeUnknown::Result.new(success?: true, errors: [],
      data: {target_id: 10, target_books: 152, sources: sources, merged: 0, failed: []})
  end

  test "merge_unknown is a dry run by default: it lists and queues nothing" do
    task = Rake::Task["books:authors:merge_unknown"]
    task.reenable
    ::Services::Books::Authors::MergeUnknown.expects(:call).with(apply: false)
      .returns(merge_unknown_result([{id: 11, name: "Anonymous", books: 136}]))
    Books::MergeUnknownAuthorsJob.expects(:perform_async).never

    out, = capture_io { task.invoke }

    assert_match(/Anonymous \(id 11, 136 books\)/, out)
    assert_match(/APPLY=1/, out)
  end

  test "merge_unknown with APPLY=1 queues the job" do
    task = Rake::Task["books:authors:merge_unknown"]
    task.reenable
    ::Services::Books::Authors::MergeUnknown.stubs(:call).returns(merge_unknown_result([{id: 11, name: "Anonymous", books: 136}]))
    Books::MergeUnknownAuthorsJob.expects(:perform_async).once

    with_env("APPLY" => "1") { capture_io { task.invoke } }
  end

  test "merge_unknown with nothing to merge says so and queues nothing" do
    task = Rake::Task["books:authors:merge_unknown"]
    task.reenable
    ::Services::Books::Authors::MergeUnknown.stubs(:call).returns(merge_unknown_result([]))
    Books::MergeUnknownAuthorsJob.expects(:perform_async).never

    out, = with_env("APPLY" => "1") { capture_io { task.invoke } }

    assert_match(/nothing to merge/i, out)
  end

  test "merge_unknown aborts when there is no canonical Unknown author" do
    task = Rake::Task["books:authors:merge_unknown"]
    task.reenable
    ::Services::Books::Authors::MergeUnknown.stubs(:call)
      .returns(::Services::Books::Authors::MergeUnknown::Result.new(success?: false, data: nil, errors: ["no author named \"Unknown\""]))

    assert_raises(SystemExit) { capture_io { task.invoke } }
  end

  def with_env(vars)
    old = vars.keys.to_h { |key| [key, ENV[key]] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| ENV[key] = value }
  end
end
