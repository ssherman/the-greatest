require "test_helper"

module Workflows
  class RecoveryTest < ActiveSupport::TestCase
    include Workflows::TestDefinitionHelpers
    include Workflows::DispatchHelper

    setup do
      # The Tolstoy fixture step is ready and never dispatched, so every sweep
      # would redispatch it. Cancelling its run keeps these tests to their own steps.
      WorkflowRun.where(enrichable: books_authors(:tolstoy), status: :running).find_each do |fixture_run|
        Coordinator.cancel(fixture_run, outcome: "test")
      end
    end

    # Planned steps are ready with dispatched_at nil, which the sweep would
    # redispatch. Marking them dispatched a minute ago lets a test isolate the
    # one step it cares about.
    def mark_dispatched(run = workflow_run)
      run.steps.update_all(dispatched_at: 1.minute.ago, dispatch_count: 1)
    end

    def set_state(step, state, **attributes)
      step.update_columns(attributes.merge(state: WorkflowStep.states[state]))
    end

    def release(step, state: :succeeded)
      set_state(step, state, released_at: Time.current, finished_at: Time.current)
    end

    def expired_lease(step, **attributes)
      set_state(step, :running, lease_expires_at: 1.second.ago, lease_token: "dead", **attributes)
    end

    test "redispatches a ready step whose window lapsed, doubling the window each time" do
      mark_dispatched
      step = workflow_run.step(:a)
      step.update_columns(dispatched_at: 11.minutes.ago, dispatch_count: 1)
      dispatched = []
      Workflows::Dispatcher.stubs(:dispatch).with { |steps| dispatched << steps.map(&:id) }
      assert_equal 1, Recovery.call[:redispatched]
      assert_equal [[step.id]], dispatched

      step.update_columns(dispatched_at: 11.minutes.ago, dispatch_count: 2) # window is now 20 minutes
      assert_equal 0, Recovery.call[:redispatched]
      assert_equal [[step.id]], dispatched
    end

    test "redispatches a ready step that was never dispatched, and leaves a recent one alone" do
      mark_dispatched
      workflow_run.step(:b).update_columns(dispatched_at: nil, dispatch_count: 0)
      Workflows::Dispatcher.expects(:dispatch).with { |steps| steps.map(&:id) == [workflow_run.step(:b).id] }.once
      Recovery.call
    end

    test "the redispatch window is capped at twelve hours" do
      mark_dispatched
      workflow_run.step(:a).update_columns(dispatched_at: 13.hours.ago, dispatch_count: 40)
      Workflows::Dispatcher.expects(:dispatch).with { |steps| steps.map(&:id) == [workflow_run.step(:a).id] }.once
      Recovery.call
    end

    test "batch limits the rows each pass takes" do
      workflow_run
      dispatched = []
      Workflows::Dispatcher.stubs(:dispatch).with { |steps| dispatched.concat(steps) }
      assert_equal 1, Recovery.call(batch: 1)[:redispatched]
      assert_equal 1, dispatched.size
    end

    test "wakes a waiting step whose time has come, and dispatches it at once" do
      mark_dispatched
      step = workflow_run.step(:a)
      set_state(step, :waiting, run_after: 1.second.ago)
      Workflows::Dispatcher.expects(:dispatch).with { |steps| steps.map(&:id) == [step.id] }.once
      counts = Recovery.call
      assert_equal ["ready", 1], [step.reload.state, counts[:woken]]
    end

    test "does not wake a waiting step that is not due" do
      step = workflow_run.step(:a)
      set_state(step, :waiting, run_after: 5.minutes.from_now)
      stub_workflow_dispatch
      assert_equal [0, "waiting"], [Recovery.call[:woken], step.reload.state]
    end

    test "reclaims an expired lease and counts the attempt" do
      step = workflow_run.step(:a)
      expired_lease(step)
      stub_workflow_dispatch
      counts = Recovery.call
      step.reload
      assert_equal ["ready", 1, 1, nil, nil], [step.state, step.attempts, counts[:reclaimed], step.lease_token, step.lease_expires_at]
    end

    test "a reclaimed step is dispatched at once even though it was dispatched recently" do
      mark_dispatched
      step = workflow_run.step(:a)
      expired_lease(step)
      Workflows::Dispatcher.expects(:dispatch).with { |steps| steps.map(&:id) == [step.id] }.once
      Recovery.call
    end

    test "leaves a running step whose lease has not expired" do
      step = workflow_run.step(:a)
      set_state(step, :running, lease_expires_at: 1.minute.from_now, lease_token: "live")
      stub_workflow_dispatch
      assert_equal [0, "running"], [Recovery.call[:reclaimed], step.reload.state]
    end

    test "an expired lease at max_attempts fails the step, releases it and advances its dependents" do
      release(workflow_run.step(:b))
      step = workflow_run.step(:a)
      expired_lease(step, attempts: 2)
      stub_workflow_dispatch
      Recovery.call
      step.reload
      assert_equal ["failed", 3], [step.state, step.attempts]
      assert step.released_at && step.finished_at
      assert_equal "ready", workflow_run.step(:c).reload.state
    end

    test "a lease expiry that loses the race to a finishing worker changes nothing" do
      step = workflow_run.step(:a)
      expired_lease(step)
      stale = WorkflowStep.find(step.id)
      Coordinator.finish(step, token: "dead", outcome: Outcome.succeeded("done"))
      assert_nil Coordinator.expire_lease(stale)
      assert_equal ["succeeded", 0], [step.reload.state, step.attempts]
    end

    test "cancels the run of a deleted author and releases the book step waiting on it" do
      book_run = plan_other_run(waits: {a: [workflow_run.step(:c)]}).data[:run]
      workflow_run.update_columns(enrichable_id: 0)
      stub_workflow_dispatch
      counts = Recovery.call
      assert_equal ["cancelled", "ready", 1], [workflow_run.reload.status, book_run.step(:a).reload.state, counts[:cancelled]]
      assert_equal "target_gone", workflow_run.step(:a).reload.outcome
    end

    test "leaves a run whose target still exists" do
      stub_workflow_dispatch
      assert_equal [0, "running"], [Recovery.call[:cancelled], workflow_run.reload.status]
    end

    test "an enrichable type that no longer exists is logged and does not stop the other runs" do
      other = plan_other_run.data[:run]
      workflow_run.update_columns(enrichable_type: "Books::NoSuchThing")
      other.update_columns(enrichable_id: 0)
      stub_workflow_dispatch
      Rails.logger.expects(:error).with { it.include?("Books::NoSuchThing") }.at_least_once
      assert_equal 1, Recovery.call[:cancelled]
      assert_equal "cancelled", other.reload.status
    end

    test "re-advances an edge left unsatisfied by an interrupted advance" do
      release(workflow_run.step(:a))
      release(workflow_run.step(:b))
      stub_workflow_dispatch
      counts = Recovery.call
      assert_equal ["ready", 2], [workflow_run.step(:c).reload.state, counts[:readvanced]]
      assert workflow_run.step(:c).dependencies.all? { it.satisfied_at }
    end

    test "re-advances a prerequisite once however many edges point at it" do
      plan_other_run(waits: {a: [workflow_run.step(:a)], b: [workflow_run.step(:a)]})
      release(workflow_run.step(:a))
      assert_equal 3, WorkflowDependency.where(prerequisite_step: workflow_run.step(:a)).count
      Coordinator.expects(:advance).with { it.id == workflow_run.step(:a).id }.once.returns([])
      stub_workflow_dispatch
      assert_equal 1, Recovery.call[:readvanced]
    end

    test "does not re-advance a finish edge whose prerequisite was released but has not finished" do
      set_state(workflow_run.step(:a), :waiting, released_at: Time.current, run_after: 1.hour.from_now)
      Coordinator.expects(:advance).never
      stub_workflow_dispatch
      assert_equal 0, Recovery.call[:readvanced]
    end

    test "closes a running run whose steps are all terminal" do
      # Every edge is satisfied, as after an advance that was interrupted at the
      # leaf: no open edge for the re-advance pass to find, only the close pass can.
      workflow_run.steps.each { release(it) }
      WorkflowDependency.where(step: workflow_run.steps).update_all(satisfied_at: Time.current)
      workflow_run.step(:c).update_columns(state: WorkflowStep.states[:failed])
      stub_workflow_dispatch
      counts = Recovery.call
      assert_equal ["completed_with_failures", 1], [workflow_run.reload.status, counts[:closed]]
      assert workflow_run.finished_at
    end

    test "does not close a run that still has an open step" do
      release(workflow_run.step(:a))
      stub_workflow_dispatch
      assert_equal [0, "running"], [Recovery.call[:closed], workflow_run.reload.status]
    end

    test "a second sweep finds nothing left to do" do
      expired_lease(workflow_run.step(:a))
      stub_workflow_dispatch
      Recovery.call
      mark_dispatched
      assert_equal({cancelled: 0, reclaimed: 0, woken: 0, readvanced: 0, closed: 0, redispatched: 0}, Recovery.call)
    end

    test "returns a count for every pass" do
      stub_workflow_dispatch
      assert_equal %i[cancelled reclaimed woken readvanced closed redispatched], Recovery.call.keys
    end

    test "a pass that raises is logged and the remaining passes still run" do
      Coordinator.stubs(:expire_lease).raises(ActiveRecord::StatementInvalid, "boom")
      expired_lease(workflow_run.step(:a))
      set_state(workflow_run.step(:b), :waiting, run_after: 1.second.ago)
      Rails.logger.expects(:error).with { it.include?("boom") }.at_least_once
      stub_workflow_dispatch
      counts = Recovery.call
      assert_equal [0, 1], [counts[:reclaimed], counts[:woken]]
    end

    test "the cron schedule runs recovery every minute" do
      assert_equal "0 * * * * *", YAML.load_file(Rails.root.join("config/schedule.yml")).dig("workflow_recovery", "cron")
    end
  end
end
