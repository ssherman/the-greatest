require "test_helper"

class WorkflowRecoveryJobTest < ActiveSupport::TestCase
  test "runs the sweep and logs the counts when anything was recovered" do
    Workflows::Recovery.expects(:call).returns({redispatched: 2, woken: 0, reclaimed: 1, cancelled: 0, readvanced: 0, closed: 0})
    Rails.logger.expects(:info).with { it.include?("redispatched=2") && it.include?("reclaimed=1") }.once
    WorkflowRecoveryJob.new.perform
  end

  test "logs nothing when there was nothing to recover" do
    Workflows::Recovery.expects(:call).returns({redispatched: 0, woken: 0, reclaimed: 0, cancelled: 0, readvanced: 0, closed: 0})
    Rails.logger.expects(:info).never
    WorkflowRecoveryJob.new.perform
  end

  test "does not retry: the next minute's sweep is the retry" do
    assert_equal 0, WorkflowRecoveryJob.get_sidekiq_options["retry"]
  end
end
