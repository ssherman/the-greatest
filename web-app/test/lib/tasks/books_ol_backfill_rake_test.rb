# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksOlBackfillRakeTest < ActiveSupport::TestCase
  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:ol_backfill")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/ol_backfill.rake").to_s }
    end
    %w[books:ol_backfill books:ol_backfill_report books:ol_backfill_revert].each { |name| Rake::Task[name].reenable }
  end

  test "a count queues one run of that many books" do
    Books::OpenLibraryBackfillJob.expects(:perform_async).with(100, instance_of(String), false)

    assert_output(/queued Open Library backfill run .*: 100 books/) { Rake::Task["books:ol_backfill"].invoke("100") }
  end

  test "all queues a run with no limit; retry_unsure is passed on" do
    Books::OpenLibraryBackfillJob.expects(:perform_async).with(nil, instance_of(String), true)

    assert_output(/all books \(retrying unsure books\)/) { Rake::Task["books:ol_backfill"].invoke("all", "retry_unsure") }
  end

  test "anything else aborts with usage and queues nothing" do
    Books::OpenLibraryBackfillJob.expects(:perform_async).never

    assert_output(nil, /usage: books:ol_backfill/) { assert_raises(SystemExit) { Rake::Task["books:ol_backfill"].invoke("soon") } }
    Rake::Task["books:ol_backfill"].reenable
    assert_output(nil, /usage: books:ol_backfill/) { assert_raises(SystemExit) { Rake::Task["books:ol_backfill"].invoke("5", "everything") } }
  end

  test "the report prints the report's lines" do
    Services::Books::OlBackfill::Report.expects(:call).returns(["Open Library backfill", "line two"])

    assert_output(/Open Library backfill\nline two/) { Rake::Task["books:ol_backfill_report"].invoke }
  end

  test "revert reverts one book, and aborts on an unknown book or a refused revert" do
    book = books_books(:war_and_peace)
    row = Books::OpenLibraryBackfill.new(old_keys: ["OL5W"])
    Services::Books::OlBackfill::Revert.expects(:call).with(book: book)
      .returns(Services::Books::OlBackfill::Revert::Result.new(success?: true, data: row, errors: []))
    assert_output(/reverted book #{book.id}/) { Rake::Task["books:ol_backfill_revert"].invoke(book.id.to_s) }

    Rake::Task["books:ol_backfill_revert"].reenable
    assert_output(nil, /no book/) { assert_raises(SystemExit) { Rake::Task["books:ol_backfill_revert"].invoke("0") } }

    Rake::Task["books:ol_backfill_revert"].reenable
    Services::Books::OlBackfill::Revert.expects(:call).with(book: book)
      .returns(Services::Books::OlBackfill::Revert::Result.new(success?: false, data: nil, errors: ["book is duplicate_pair"]))
    assert_output(nil, /book is duplicate_pair/) { assert_raises(SystemExit) { Rake::Task["books:ol_backfill_revert"].invoke(book.id.to_s) } }
  end
end
