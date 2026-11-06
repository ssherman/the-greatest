require "test_helper"

class Books::GoodreadsRebuild::QueueEnrichmentJobTest < ActiveSupport::TestCase
  test "tops up to the configured in_flight" do
    Rails.application.config.x.goodreads_rebuild.stubs(:in_flight).returns(42)
    Services::Books::GoodreadsRebuild::QueueEnrichment.expects(:call).with(in_flight: 42)
      .returns(Struct.new(:data).new({started: 0, in_flight: 0, waiting: 0}))
    Rails.logger.stubs(:info)

    Books::GoodreadsRebuild::QueueEnrichmentJob.new.perform
  end
end
