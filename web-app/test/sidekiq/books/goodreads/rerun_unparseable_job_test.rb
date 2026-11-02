# frozen_string_literal: true

require "test_helper"

class Books::Goodreads::RerunUnparseableJobTest < ActiveSupport::TestCase
  RERUN = Services::Books::GoodreadsEnrichment::RerunUnparseable

  def result = RERUN::Result.new(success?: true, data: {started: 0, remaining: 0}, errors: [])

  test "re-runs up to the default limit" do
    RERUN.expects(:call).with(limit: Books::Goodreads::RerunUnparseableJob::DEFAULT_LIMIT).returns(result)

    Books::Goodreads::RerunUnparseableJob.new.perform
  end

  test "passes a given limit through" do
    RERUN.expects(:call).with(limit: 20).returns(result)

    Books::Goodreads::RerunUnparseableJob.new.perform(20)
  end
end
