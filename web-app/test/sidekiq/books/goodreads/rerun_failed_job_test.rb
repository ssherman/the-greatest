# frozen_string_literal: true

require "test_helper"

class Books::Goodreads::RerunFailedJobTest < ActiveSupport::TestCase
  RERUN = Services::Books::GoodreadsEnrichment::RerunFailed

  def result = RERUN::Result.new(success?: true, data: {started: 0, remaining: 0}, errors: [])

  test "re-runs up to the default limit" do
    RERUN.expects(:call).with(limit: Books::Goodreads::RerunFailedJob::DEFAULT_LIMIT).returns(result)

    Books::Goodreads::RerunFailedJob.new.perform
  end

  test "passes a given limit through" do
    RERUN.expects(:call).with(limit: 20).returns(result)

    Books::Goodreads::RerunFailedJob.new.perform(20)
  end
end
