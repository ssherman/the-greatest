# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksGoodreadsRebuildRakeTest < ActiveSupport::TestCase
  REBUILD = Services::Books::GoodreadsRebuild

  setup do
    # Load only this rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:goodreads_rebuild:cohorts")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/goodreads_rebuild.rake").to_s }
    end
    Rake::Task.tasks.each(&:reenable)
  end

  test "cohorts prints the counts" do
    REBUILD::Cohort.expects(:counts).returns({"trusted" => 2, "derived" => 3, "only_on_user_favorites" => 1})

    assert_output(/post-import books: trusted 2, derived 3, only_on_user_favorites 1/) do
      Rake::Task["books:goodreads_rebuild:cohorts"].invoke
    end
  end

  def retire_result(applied:)
    Struct.new(:success?, :data, :errors, keyword_init: true)
      .new(success?: true, data: {counts: {"relink" => 2691, "strip_identifier" => 2091}, applied: applied}, errors: [])
  end

  test "retire_replay_proposals is a dry run without apply" do
    REBUILD::RetireReplayProposals.expects(:call).with(apply: false).returns(retire_result(applied: false))

    assert_output(/relink 2691, strip_identifier 2091.*dry run: nothing changed; run books:goodreads_rebuild:retire_replay_proposals\[apply\]/m) do
      Rake::Task["books:goodreads_rebuild:retire_replay_proposals"].invoke
    end
  end

  test "survey queues the job" do
    Books::GoodreadsRebuild::SurveyJob.expects(:perform_async).with(200, false)
    assert_output(/queued survey of 200 derived books\n/) { Rake::Task["books:goodreads_rebuild:survey"].invoke("200") }
  end

  test "survey all and redo" do
    Books::GoodreadsRebuild::SurveyJob.expects(:perform_async).with(nil, false)
    assert_output(/queued survey of all derived books/) { Rake::Task["books:goodreads_rebuild:survey"].invoke("all") }

    Rake::Task["books:goodreads_rebuild:survey"].reenable
    Books::GoodreadsRebuild::SurveyJob.expects(:perform_async).with(nil, true)
    assert_output(/queued survey of all derived books \(redo\)/) { Rake::Task["books:goodreads_rebuild:survey"].invoke("all", "redo") }
  end

  test "survey rejects a bad limit" do
    Books::GoodreadsRebuild::SurveyJob.expects(:perform_async).never
    assert_raises(SystemExit) do
      capture_io { Rake::Task["books:goodreads_rebuild:survey"].invoke("bogus") }
    end
  end

  def evidence_result(looked_up: 7, stopped: false, error: nil)
    Struct.new(:success?, :data, :errors, keyword_init: true)
      .new(success?: !stopped, data: {looked_up: looked_up, stopped: stopped, error: error}, errors: [error].compact)
  end

  test "gather_evidence passes the thread count" do
    REBUILD::EvidenceRun.expects(:call).with(threads: 8).returns(evidence_result)
    assert_output(/looked up 7 editions/) { Rake::Task["books:goodreads_rebuild:gather_evidence"].invoke("8") }
  end

  test "gather_evidence defaults to 4 threads and reports a stop" do
    REBUILD::EvidenceRun.expects(:call).with(threads: 4).returns(evidence_result(looked_up: 2, stopped: true, error: "down"))
    assert_output(/looked up 2 editions -- stopped: down/) { Rake::Task["books:goodreads_rebuild:gather_evidence"].invoke }
  end

  test "export_evidence writes to the default path" do
    REBUILD::EvidenceTransfer.expects(:export).with("tmp/rebuild_edition_evidence.jsonl.gz").returns(12)
    assert_output(/exported 12 evidence rows to tmp\/rebuild_edition_evidence.jsonl.gz/) do
      Rake::Task["books:goodreads_rebuild:export_evidence"].invoke
    end
  end

  test "import_evidence needs a path and prints the counts" do
    REBUILD::EvidenceTransfer.expects(:import).with("/tmp/e.jsonl.gz").returns({"imported" => 5, "no_edition_here" => 1})
    assert_output(/imported 5, no_edition_here 1/) { Rake::Task["books:goodreads_rebuild:import_evidence"].invoke("/tmp/e.jsonl.gz") }

    Rake::Task["books:goodreads_rebuild:import_evidence"].reenable
    assert_raises(SystemExit) { capture_io { Rake::Task["books:goodreads_rebuild:import_evidence"].invoke } }
  end

  test "survey_report prints the report" do
    REBUILD::SurveyReport.expects(:call).returns("surveyed: 5")
    assert_output(/surveyed: 5/) { Rake::Task["books:goodreads_rebuild:survey_report"].invoke }
  end

  test "retire_replay_proposals[apply] retires them" do
    REBUILD::RetireReplayProposals.expects(:call).with(apply: true).returns(retire_result(applied: true))

    assert_output(/relink 2691, strip_identifier 2091.*retired/m) do
      Rake::Task["books:goodreads_rebuild:retire_replay_proposals"].invoke("apply")
    end
  end
end
