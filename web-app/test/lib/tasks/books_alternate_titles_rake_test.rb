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
end
