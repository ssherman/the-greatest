require "test_helper"

class WorkflowStepJobTest < ActiveSupport::TestCase
  include Workflows::TestDefinitionHelpers

  setup { WorkflowStepJob.clear }

  def perform(step, jid: "j")
    WorkflowStepJob.new.tap { it.jid = jid }.perform(step.id)
  end

  test "runs the adapter with Current.workflow_step_id set and records the outcome" do
    Workflows::TestDefinition.outcomes[:a] = ->(step:, run:, target:) {
      Workflows::Outcome.succeeded("x", {"seen" => Current.workflow_step_id})
    }
    step = workflow_run.step(:a)
    perform(step)
    step.reload
    assert_equal ["succeeded", "x", step.id], [step.state, step.outcome, step.result["seen"]]
    assert_nil Current.workflow_step_id
  end

  test "dispatches the steps that became ready" do
    Sidekiq::Testing.fake! do
      perform(workflow_run.step(:a))
      assert_equal [], WorkflowStepJob.jobs
      perform(workflow_run.step(:b))
      assert_equal "ready", workflow_run.step(:c).reload.state
      assert_equal [[workflow_run.step(:c).id]], WorkflowStepJob.jobs.map { it["args"] }
    end
  end

  test "the diamond's c reads a's result (Goodreads shape)" do
    Workflows::TestDefinition.outcomes[:a] = ->(**) { Workflows::Outcome.succeeded("done", {"qid" => "Q1"}) }
    Workflows::TestDefinition.outcomes[:c] = ->(step:, run:, target:) {
      Workflows::Outcome.succeeded(run.step(:a).result.fetch("qid"))
    }
    # Inline mode: finishing b makes c ready and the dispatch runs it at once.
    perform(workflow_run.step(:a))
    perform(workflow_run.step(:b))
    assert_equal "Q1", workflow_run.step(:c).reload.outcome
  end

  test "an adapter error is recorded as an attempt and the step waits" do
    Workflows::TestDefinition.outcomes[:a] = ->(**) { raise "boom" }
    perform(workflow_run.step(:a))
    assert_equal ["waiting", 1, "RuntimeError: boom"], workflow_run.step(:a).reload.values_at(:state, :attempts, :error)
  end

  test "an error on the last attempt fails the step and dispatches what that frees" do
    Workflows::TestDefinition.outcomes[:a] = ->(**) { raise "boom" }
    workflow_run.step(:a).update_columns(max_attempts: 1)
    perform(workflow_run.step(:b))
    Sidekiq::Testing.fake! do
      perform(workflow_run.step(:a))
      assert_equal ["failed", "ready"], [workflow_run.step(:a).reload.state, workflow_run.step(:c).reload.state]
      assert_equal [[workflow_run.step(:c).id]], WorkflowStepJob.jobs.map { it["args"] }
    end
  end

  test "a missing target cancels the run as target_gone" do
    workflow_run.update_columns(enrichable_id: 0)
    perform(workflow_run.step(:a))
    assert_equal ["cancelled", "target_gone"], [workflow_run.reload.status, workflow_run.step(:a).reload.outcome]
  end

  test "a step key the definition no longer has is skipped as unknown_step" do
    workflow_run.step(:a).update_columns(key: "gone")
    perform(workflow_run.step(:gone))
    assert_equal ["skipped", "unknown_step"], workflow_run.step(:gone).reload.values_at(:state, :outcome)
  end

  test "a run whose workflow is no longer registered is skipped as unknown_step" do
    step = workflow_run.step(:a)
    Workflows::Registry.unregister(Workflows::TestDefinition.workflow)
    perform(step)
    assert_equal ["skipped", "unknown_step"], step.reload.values_at(:state, :outcome)
  end

  test "Sidekiq::Shutdown propagates and leaves the step claimable by the same jid" do
    Workflows::TestDefinition.outcomes[:a] = ->(**) { raise Sidekiq::Shutdown }
    assert_raises(Sidekiq::Shutdown) { perform(workflow_run.step(:a)) }
    assert Workflows::Coordinator.claim(workflow_run.step(:a).id, token: "j")
  end

  test "a second message for a claimed step does nothing" do
    Workflows::Coordinator.claim(workflow_run.step(:a).id, token: "other")
    Workflows::TestDefinition.outcomes[:a] = ->(**) { flunk "ran twice" }
    perform(workflow_run.step(:a))
    assert_equal "running", workflow_run.step(:a).reload.state
  end

  test "the adapter and the terminal write run outside any transaction the job opened" do
    depths = []
    Workflows::TestDefinition.outcomes[:a] = ->(**) {
      depths << ActiveRecord::Base.connection.open_transactions
      Workflows::Outcome.succeeded("x")
    }
    workflow_run
    baseline = ActiveRecord::Base.connection.open_transactions
    perform(workflow_run.step(:a))
    assert_equal [baseline], depths
  end
end
