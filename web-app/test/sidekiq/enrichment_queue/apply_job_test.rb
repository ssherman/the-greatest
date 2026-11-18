require "test_helper"

class EnrichmentQueue::ApplyJobTest < ActiveSupport::TestCase
  setup do
    @row = ::EnrichmentRequest.create!(enrichable: books_books(:war_and_peace), kind: "books.test_type", reason: "missing",
      status: :submitted, answer: {"value" => "x"})
  end

  test "perform applies the request" do
    Services::EnrichmentQueue::Apply.expects(:call).with(request_id: @row.id)
    ::EnrichmentQueue::ApplyJob.new.perform(@row.id)
  end

  test "when retries are exhausted the row is marked failed with the error message" do
    ::EnrichmentQueue::ApplyJob.sidekiq_retries_exhausted_block.call({"args" => [@row.id]}, StandardError.new("boom"))
    @row.reload
    assert_equal ["failed", "boom"], [@row.status, @row.error]
  end

  test "runs on the low queue with three retries" do
    options = ::EnrichmentQueue::ApplyJob.get_sidekiq_options
    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end
end
