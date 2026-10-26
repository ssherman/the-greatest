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
    %w[books:verify books:verify_report books:verify_revert books:verify_revert_route books:verify_keep_bigger].each { |name| Rake::Task[name].reenable }
  end

  def keep_bigger_result(found:, reverted: 0, failed: [], run_id: nil)
    Services::Books::Verification::KeepBiggerWork::Result.new(success?: true, errors: [],
      data: {found: found, reverted: reverted, failed: failed, run_id: run_id, samples: ["book 1 \"Seize the Day\": OL5W (1 editions) -> OL9W (30 editions)"]})
  end

  test "keep_bigger with no argument is a dry run that prints what it found" do
    Services::Books::Verification::KeepBiggerWork.expects(:call).with(apply: false).returns(keep_bigger_result(found: 278))

    assert_output(/keep bigger work \(dry run\): 278 books.*Seize the Day/m) { Rake::Task["books:verify_keep_bigger"].invoke }
  end

  test "keep_bigger[apply] reverts and queues the redo, and says so" do
    Services::Books::Verification::KeepBiggerWork.expects(:call).with(apply: true).returns(keep_bigger_result(found: 2, reverted: 2, run_id: "run-9"))

    assert_output(/keep bigger work \(applied\): 2 books, reverted 2.*queued redo run run-9/m) { Rake::Task["books:verify_keep_bigger"].invoke("apply") }
  end

  test "keep_bigger with an unknown argument aborts with usage" do
    Services::Books::Verification::KeepBiggerWork.expects(:call).never

    assert_output(nil, /usage: books:verify_keep_bigger/) { assert_raises(SystemExit) { Rake::Task["books:verify_keep_bigger"].invoke("now") } }
  end

  test "books:verify refuses redo, which needs the books named" do
    Books::VerificationJob.expects(:perform_async).never

    assert_output(nil, /redo/) { assert_raises(SystemExit) { Rake::Task["books:verify"].invoke("all", "redo") } }
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

  test "revert of a row a second chance settled undoes only the second chance, and says so" do
    book = books_books(:war_and_peace)
    Books::Verification.create!(book: book, work_outcome: :keyed, run_id: "run-2", lookup: :resolve_candidate, stage: :done,
      second_chance_at: 1.hour.ago, prior_outcome: Books::Verification.work_outcomes[:unsure], prior_keys: [], new_key: "OL1W")
    # (Not Revert.expects(:call).never: RevertSecondChance inherits Revert's .call, so Mocha would catch it too.)
    # The full Revert would leave the row reverted; the second-chance revert leaves it unsure.
    assert_output(/reverted the second chance on book #{book.id}: back to unsure/) { Rake::Task["books:verify_revert"].invoke(book.id.to_s) }
    assert_equal "unsure", Books::Verification.find_by(book: book).work_outcome
  end

  test "revert of a second-chance row the second chance did not settle takes the full revert" do
    book = books_books(:war_and_peace)
    row = Books::Verification.create!(book: book, work_outcome: :removed, run_id: "run-2", lookup: :resolve, stage: :done,
      second_chance_at: 1.hour.ago, prior_outcome: Books::Verification.work_outcomes[:removed], old_keys: ["OL5W"])
    Services::Books::Verification::Revert.expects(:call).with(book: book)
      .returns(Services::Books::Verification::Revert::Result.new(success?: true, data: {row: row, skipped: 0}, errors: []))

    assert_output(/reverted book #{book.id}: work keys back to/) { Rake::Task["books:verify_revert"].invoke(book.id.to_s) }
  end

  test "revert_route takes the second_chance_matcher pseudo-route and aborts on an unknown one" do
    Services::Books::Verification::RevertSecondChance.expects(:route).with("second_chance_matcher").returns({reverted: 3, failed: 1})

    assert_output(/route second_chance_matcher: reverted 3, failed 1/) { Rake::Task["books:verify_revert_route"].invoke("second_chance_matcher") }

    Rake::Task["books:verify_revert_route"].reenable
    assert_output(nil, /usage: books:verify_revert_route\[.*second_chance_matcher\]/) do
      assert_raises(SystemExit) { Rake::Task["books:verify_revert_route"].invoke("everything") }
    end
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
