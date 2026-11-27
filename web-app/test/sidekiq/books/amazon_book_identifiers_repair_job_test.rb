# frozen_string_literal: true

require "test_helper"

class Books::AmazonBookIdentifiersRepairJobTest < ActiveSupport::TestCase
  Repair = Services::Books::AmazonBookIdentifiersRepair

  def chunk(last_id:, done:, checked: 2, same_book: 1, editions_written: 1, identifiers_written: 2, editions_flagged: 0)
    Repair::Result.new(success?: true, errors: [], data: {checked:, same_book:, editions_written:, identifiers_written:,
                                                          editions_flagged:, last_id:, done:})
  end

  test "runs one chunk and queues the next with the running totals" do
    Repair.expects(:call).with(after_id: 40, dry_run: true).returns(chunk(last_id: 90, done: false))
    Books::AmazonBookIdentifiersRepairJob.expects(:perform_async)
      .with("run-1", true, 90, {"checked" => 7, "same_book" => 1, "editions_written" => 1, "identifiers_written" => 2, "editions_flagged" => 3})

    Books::AmazonBookIdentifiersRepairJob.new.perform("run-1", true, 40, {"checked" => 5, "editions_flagged" => 3})
  end

  test "the last chunk queues nothing" do
    Repair.expects(:call).with(after_id: 0, dry_run: false).returns(chunk(last_id: 0, done: true, checked: 0))
    Books::AmazonBookIdentifiersRepairJob.expects(:perform_async).never

    Books::AmazonBookIdentifiersRepairJob.new.perform("run-1", false)
  end

  test "runs on the low queue without retries" do
    options = Books::AmazonBookIdentifiersRepairJob.get_sidekiq_options
    assert_equal ["low", false], [options["queue"].to_s, options["retry"]]
  end
end
