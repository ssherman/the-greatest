# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksAlternateTitlesRakeTest < ActiveSupport::TestCase
  setup do
    unless Rake::Task.task_defined?("books:alternate_titles:backfill")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/alternate_titles.rake").to_s }
    end
    @task = Rake::Task["books:alternate_titles:backfill"]
    @task.reenable
  end

  test "runs the backfill and prints the count" do
    ::Services::AlternateTitles::Backfill.expects(:all).returns(5)

    assert_output(/5 rows created/) { @task.invoke }
  end

  test "review task enqueues the scope" do
    task = Rake::Task["books:alternate_titles:review"]
    task.reenable
    ::Books::AlternateTitles::ReviewJob.expects(:enqueue).with("ranked").returns(3)

    assert_output(/3 books queued/) { task.invoke }
  end

  test "restore task keeps the row" do
    row = AlternateTitle.create!(titleable: books_books(:got), title: "Zed", source: :legacy, status: :removed,
      verdict: :not_same_work, category: :junk, decided_by: :ai)
    task = Rake::Task["books:alternate_titles:restore"]
    task.reenable

    capture_io { task.invoke(row.id.to_s) }

    assert_equal "kept", row.reload.status
    assert_equal "not_same_work", row.verdict
  end

  test "report task prints the report" do
    task = Rake::Task["books:alternate_titles:report"]
    task.reenable
    ::Services::Books::AlternateTitles::Report.expects(:call).returns("THE REPORT")

    assert_output(/THE REPORT/) { task.invoke }
  end

  test "undo_findings stays a dry run unless told to apply" do
    result = ::Services::Books::AlternateTitles::UndoFindings::Result.new(success?: true, errors: [], data: {books: 1, findings_checked: 2,
                                                                                                             undone: {identifier_destroyed: 1, source_restored: 0, identifier_gone: 0}, wrong_work: [{book_id: 1, title: "T", work_key: "OL1W", work_title: "W"}], samples: ["a sample"]})
    ::Services::Books::AlternateTitles::UndoFindings.expects(:call).with(apply: false).returns(result)
    task = Rake::Task["books:alternate_titles:undo_findings"]
    task.reenable

    assert_output(/dry run.*identifier_destroyed: 1.*OL1W.*a sample/m) { task.invoke }
  end

  test "undo_findings applies only for the exact arg" do
    result = ::Services::Books::AlternateTitles::UndoFindings::Result.new(success?: true, errors: [], data: {books: 0, findings_checked: 0,
                                                                                                             undone: {identifier_destroyed: 0, source_restored: 0, identifier_gone: 0}, wrong_work: [], samples: []})
    ::Services::Books::AlternateTitles::UndoFindings.expects(:call).with(apply: true).returns(result)
    task = Rake::Task["books:alternate_titles:undo_findings"]
    task.reenable

    assert_output(/applied/) { task.invoke("apply") }
  end

  test "redo_finding reverses the finding" do
    finding = Books::VerificationFinding.new
    finding.stubs(:id).returns(7)
    Books::VerificationFinding.expects(:find).with("7").returns(finding)
    ::Services::Books::AlternateTitles::UndoFindings.expects(:redo).with(finding: finding)
      .returns(::Services::Books::AlternateTitles::UndoFindings::Result.new(success?: true, errors: []))
    task = Rake::Task["books:alternate_titles:redo_finding"]
    task.reenable

    assert_output(/redid finding 7/) { task.invoke("7") }
  end
end
