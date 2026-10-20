require "test_helper"

module Workflows
  class CoordinatorTest < ActiveSupport::TestCase
    include Workflows::TestDefinitionHelpers

    test "evaluate moves a blocked step with all edges satisfied to ready" do
      workflow_run.step(:a).update!(state: :succeeded, released_at: Time.current, finished_at: Time.current)
      workflow_run.step(:b).update!(state: :running, released_at: Time.current)
      assert_equal :ready, Coordinator.evaluate(workflow_run.step(:c))
      assert_equal "ready", workflow_run.step(:c).state
      assert workflow_run.step(:c).dependencies.all? { it.satisfied_at }
    end

    test "evaluate keeps a step blocked while a finish prerequisite is released but not finished" do
      workflow_run.step(:a).update!(state: :running)
      workflow_run.step(:b).update!(state: :running)
      assert_equal :blocked, Coordinator.evaluate(workflow_run.step(:c))
      assert_not workflow_run.step(:c).released?
    end

    test "release passes through a finish edge: a step whose prerequisites are all released is released, still blocked" do
      workflow_run.step(:a).update!(state: :running, released_at: Time.current)
      workflow_run.step(:b).update!(state: :running, released_at: Time.current)
      assert_equal :released, Coordinator.evaluate(workflow_run.step(:c))
      c = workflow_run.step(:c)
      assert_equal ["blocked", true], [c.state, c.released?]
    end

    test "evaluate does not release the same step twice" do
      workflow_run.step(:a).update!(state: :running, released_at: Time.current)
      workflow_run.step(:b).update!(state: :running, released_at: Time.current)
      c = workflow_run.step(:c)
      assert_equal :released, Coordinator.evaluate(c)
      stamp = c.reload.released_at
      assert_equal :blocked, Coordinator.evaluate(c)
      assert_equal stamp, c.reload.released_at
    end

    test "evaluate is safe to call twice on a step that became ready" do
      workflow_run.step(:a).update!(state: :succeeded, released_at: Time.current)
      workflow_run.step(:b).update!(state: :succeeded, released_at: Time.current)
      c = workflow_run.step(:c)
      assert_equal [:ready, :ready], [Coordinator.evaluate(c), Coordinator.evaluate(c)]
      assert_equal "ready", c.reload.state
    end

    test "evaluate leaves a step that is not blocked alone" do
      a = workflow_run.step(:a)
      a.update!(state: :running)
      assert_equal :blocked, Coordinator.evaluate(a)
      assert_equal "running", a.reload.state
    end

    test "cancel skips every non-terminal step with the outcome and cancels the run" do
      workflow_run.step(:a).update!(state: :succeeded, outcome: "done", finished_at: Time.current, released_at: Time.current)
      workflow_run.step(:b).update!(state: :running, lease_token: "t", lease_expires_at: 5.minutes.from_now)
      Coordinator.cancel(workflow_run, outcome: "superseded")

      assert_equal "cancelled", workflow_run.reload.status
      assert workflow_run.finished_at
      a, b, c = %i[a b c].map { workflow_run.step(it) }
      assert_equal ["succeeded", "done"], [a.state, a.outcome]
      assert_equal ["skipped", "superseded", true, true], [b.state, b.outcome, b.released?, b.finished_at.present?]
      assert_equal [nil, nil], [b.lease_token, b.lease_expires_at]
      assert_equal ["skipped", "superseded", true], [c.state, c.outcome, c.released?]
    end
  end
end
