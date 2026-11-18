require "test_helper"

class EnrichmentQueue::FillJobTest < ActiveSupport::TestCase
  test "perform fills the named queue with the scope and limit it was given" do
    Services::EnrichmentQueue::Fill.expects(:call).with(kind: "books.test_type", scope: "all", limit: nil)
      .returns(Services::EnrichmentQueue::Fill::Result.new(success?: true, data: {inserted: 0, reopened: 0, reprioritized: 0}, errors: []))
    ::EnrichmentQueue::FillJob.new.perform("books.test_type", "all", nil)
  end

  test "perform does not raise when the fill fails" do
    Services::EnrichmentQueue::Fill.stubs(:call)
      .returns(Services::EnrichmentQueue::Fill::Result.new(success?: false, data: nil, errors: ["unknown"]))
    assert_nothing_raised { ::EnrichmentQueue::FillJob.new.perform("books.nope", "ranked", nil) }
  end
end
