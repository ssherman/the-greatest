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

  test "a count and flags queue one run" do
    Books::VerificationJob.expects(:perform_async).with(100, instance_of(String), %w[post_import unranked])

    assert_output(/queued verification run .*: 100 books \(post_import, unranked\)/) { Rake::Task["books:verify"].invoke("100", "post_import", "unranked") }
  end

  test "all with no flags queues a ranked, pre-import run" do
    Books::VerificationJob.expects(:perform_async).with(nil, instance_of(String), [])

    assert_output(/all books \(ranked, pre-import\)/) { Rake::Task["books:verify"].invoke("all") }
  end

  test "an unknown flag or count aborts with usage" do
    Books::VerificationJob.expects(:perform_async).never

    assert_output(nil, /usage: books:verify/) { assert_raises(SystemExit) { Rake::Task["books:verify"].invoke("5", "everything") } }
    Rake::Task["books:verify"].reenable
    assert_output(nil, /usage: books:verify/) { assert_raises(SystemExit) { Rake::Task["books:verify"].invoke("soon") } }
  end

  test "the report prints the report's lines" do
    Services::Books::Verification::Report.expects(:call).returns(["Book verification pass", "line two"])

    assert_output(/Book verification pass\nline two/) { Rake::Task["books:verify_report"].invoke }
  end

  test "revert reverts one book, and aborts on an unknown book or a refused revert" do
    book = books_books(:war_and_peace)
    row = Books::Verification.new(old_keys: ["OL5W"])
    Services::Books::Verification::Revert.expects(:call).with(book: book)
      .returns(Services::Books::Verification::Revert::Result.new(success?: true, data: {row: row, skipped: 2}, errors: []))
    assert_output(/reverted book #{book.id}.*2 identifiers had moved/) { Rake::Task["books:verify_revert"].invoke(book.id.to_s) }

    Rake::Task["books:verify_revert"].reenable
    assert_output(nil, /no book/) { assert_raises(SystemExit) { Rake::Task["books:verify_revert"].invoke("0") } }

    Rake::Task["books:verify_revert"].reenable
    Services::Books::Verification::Revert.expects(:call).with(book: book)
      .returns(Services::Books::Verification::Revert::Result.new(success?: false, data: nil, errors: ["book is duplicate_pair"]))
    assert_output(nil, /book is duplicate_pair/) { assert_raises(SystemExit) { Rake::Task["books:verify_revert"].invoke(book.id.to_s) } }
  end
end
