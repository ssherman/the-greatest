# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksVerifyRakeTest < ActiveSupport::TestCase
  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:verify")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/verify.rake").to_s }
    end
    %w[books:verify books:verify_report books:verify_revert].each { |name| Rake::Task[name].reenable }
  end

  test "a count queues one run of that many books" do
    Books::VerificationJob.expects(:perform_async).with(100, instance_of(String), false)

    assert_output(/queued verification run .*: 100 books/) { Rake::Task["books:verify"].invoke("100") }
  end

  test "all queues a run with no limit; retry_unsure is passed on" do
    Books::VerificationJob.expects(:perform_async).with(nil, instance_of(String), true)

    assert_output(/all books \(retrying unsure books\)/) { Rake::Task["books:verify"].invoke("all", "retry_unsure") }
  end

  test "anything else aborts with usage and queues nothing" do
    Books::VerificationJob.expects(:perform_async).never

    assert_output(nil, /usage: books:verify/) { assert_raises(SystemExit) { Rake::Task["books:verify"].invoke("soon") } }
    Rake::Task["books:verify"].reenable
    assert_output(nil, /usage: books:verify/) { assert_raises(SystemExit) { Rake::Task["books:verify"].invoke("5", "everything") } }
  end

  test "the report prints the report's lines" do
    Services::Books::Verification::Report.expects(:call).returns(["Open Library backfill", "line two"])

    assert_output(/Open Library backfill\nline two/) { Rake::Task["books:verify_report"].invoke }
  end

  test "revert reverts one book, and aborts on an unknown book or a refused revert" do
    book = books_books(:war_and_peace)
    row = Books::Verification.new(old_keys: ["OL5W"])
    Services::Books::Verification::Revert.expects(:call).with(book: book)
      .returns(Services::Books::Verification::Revert::Result.new(success?: true, data: row, errors: []))
    assert_output(/reverted book #{book.id}/) { Rake::Task["books:verify_revert"].invoke(book.id.to_s) }

    Rake::Task["books:verify_revert"].reenable
    assert_output(nil, /no book/) { assert_raises(SystemExit) { Rake::Task["books:verify_revert"].invoke("0") } }

    Rake::Task["books:verify_revert"].reenable
    Services::Books::Verification::Revert.expects(:call).with(book: book)
      .returns(Services::Books::Verification::Revert::Result.new(success?: false, data: nil, errors: ["book is duplicate_pair"]))
    assert_output(nil, /book is duplicate_pair/) { assert_raises(SystemExit) { Rake::Task["books:verify_revert"].invoke(book.id.to_s) } }
  end
end
