require "test_helper"

module Workflows
  class DispatcherTest < ActiveSupport::TestCase
    include Workflows::TestDefinitionHelpers

    setup { WorkflowStepJob.clear }

    test "dispatch enqueues on the step's own queue and counts the dispatch" do
      Sidekiq::Testing.fake! do
        Workflows::Dispatcher.dispatch([workflow_run.step(:a)])
        step = workflow_run.step(:a).reload
        assert_equal ["author_chain", [step.id], 1], [WorkflowStepJob.jobs.last["queue"], WorkflowStepJob.jobs.last["args"], step.dispatch_count]
        assert step.dispatched_at
      end
    end

    test "dispatch skips a step that is not ready" do
      Sidekiq::Testing.fake! do
        Workflows::Dispatcher.dispatch([workflow_run.step(:c)])
        assert_equal [0, 0], [WorkflowStepJob.jobs.size, workflow_run.step(:c).reload.dispatch_count]
      end
    end

    test "dispatch judges readiness from the database, not the in-memory step" do
      Sidekiq::Testing.fake! do
        stale = workflow_run.step(:a)
        WorkflowStep.where(id: stale.id).update_all(state: WorkflowStep.states[:running])
        Workflows::Dispatcher.dispatch([stale])
        assert_equal 0, WorkflowStepJob.jobs.size
      end
    end

    test "a Redis error on enqueue is logged, does not raise, and leaves the step for the recovery sweep" do
      WorkflowStepJob.stubs(:set).raises(RedisClient::CannotConnectError, "down")
      step_a = workflow_run.step(:a)
      Rails.logger.expects(:error).with { it.include?("step #{step_a.id}") }.once
      Rails.logger.expects(:error).with { it.include?("step #{workflow_run.step(:b).id}") }.once
      assert_nothing_raised { Workflows::Dispatcher.dispatch([step_a, workflow_run.step(:b)]) }
      assert_equal [[nil, 0], [nil, 0]], %i[a b].map { workflow_run.step(it).reload.values_at(:dispatched_at, :dispatch_count) }
    end

    test "any error on a step is logged and swallowed, since the caller's transaction already committed" do
      WorkflowStepJob.stubs(:set).raises(ConnectionPool::TimeoutError, "no connection")
      step_a = workflow_run.step(:a)
      Rails.logger.expects(:error).with { it.include?("step #{step_a.id}") && it.include?("ConnectionPool::TimeoutError") }.once
      assert_nothing_raised { Workflows::Dispatcher.dispatch([step_a]) }
      assert_equal [nil, 0], step_a.reload.values_at(:dispatched_at, :dispatch_count)
    end

    test "a failed enqueue does not stop the remaining steps from being dispatched" do
      Sidekiq::Testing.fake! do
        setter = WorkflowStepJob.set(queue: "author_chain")
        WorkflowStepJob.stubs(:set).raises(RedisClient::CannotConnectError, "down").then.returns(setter)
        Rails.logger.stubs(:error)
        Workflows::Dispatcher.dispatch([workflow_run.step(:a), workflow_run.step(:b)])
        assert_equal [0, 1], %i[a b].map { workflow_run.step(it).reload.dispatch_count }
        assert_equal 1, WorkflowStepJob.jobs.size
      end
    end

    test "after_commit dispatches once the outermost transaction commits" do
      dispatched = false
      Workflows::Dispatcher.expects(:dispatch).with([:steps]).once.with { dispatched = true }
      ActiveRecord::Base.transaction do
        Workflows::Dispatcher.after_commit([:steps])
        assert_not dispatched, "dispatched before the transaction committed"
      end
      assert dispatched
    end
  end
end
