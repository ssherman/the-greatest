require "test_helper"

class EnrichmentQueue::ResearchJobTest < ActiveSupport::TestCase
  test "perform researches one row of the kind it was given" do
    Services::EnrichmentQueue::Research.expects(:call).with(kind: "books.origin")
      .returns(Services::EnrichmentQueue::Research::Result.new(success?: true, data: {request: nil}, errors: []))
    ::EnrichmentQueue::ResearchJob.new.perform("books.origin")
  end

  test "it runs on the low queue and is never retried" do
    options = ::EnrichmentQueue::ResearchJob.get_sidekiq_options
    assert_equal ["low", 0], [options["queue"].to_s, options["retry"]]
  end
end
