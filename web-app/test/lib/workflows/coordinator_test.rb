require "test_helper"

module Workflows
  class CoordinatorTest < ActiveSupport::TestCase
    include Workflows::TestDefinitionHelpers

    # x, then y (finish edge on x), then z (finish edge on y). y skips itself on
    # request, and x records its on_terminal calls: the chain exercises the work
    # list in advance and the callback.
    class ChainDefinition < Workflows::Definition
      TERMINATED = []

      workflow "test.chain"
      version 1
      target_class ::Books::Author

      add_step key: :x, queue: :author_chain, adapter: ->(**) {}, on_terminal: ->(step, target) {
        raise "callback boom" if step.run.options["raise_terminal"]
        TERMINATED << [step.key, target.class]
      }
      add_step key: :y, queue: :author_chain, adapter: ->(**) {}, waits_on: {x: :finish},
        skip_if: ->(run) { run.options["skip_y"] ? "not_needed" : nil }
      add_step key: :z, queue: :author_chain, adapter: ->(**) {}, waits_on: {y: :finish}
    end

    setup do
      Workflows::Registry.register("test.chain", ChainDefinition)
      ChainDefinition::TERMINATED.clear
    end
    teardown { Workflows::Registry.unregister("test.chain") }

    TOKEN = "jid-1"

    # Claims the step with a fixed token and finishes it with the outcome.
    def finish(key, outcome, run: workflow_run)
      step = run.step(key)
      Coordinator.claim(step.id, token: TOKEN)
      Coordinator.finish(step, token: TOKEN, outcome: outcome)
    end

    def plan_chain(**args)
      Workflows::Planner.call(definition: ChainDefinition, enrichable: books_authors(:king), initiated_by: "test", **args).data[:run]
    end

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

    test "close_if_finished leaves a run with open steps running and closes a finished one once" do
      assert_equal [false, "running"], [Coordinator.close_if_finished(workflow_run), workflow_run.reload.status]
      workflow_run.steps.update_all(state: WorkflowStep.states[:succeeded])
      assert_equal [true, "completed"], [Coordinator.close_if_finished(workflow_run), workflow_run.reload.status]
      assert workflow_run.finished_at
      assert_equal false, Coordinator.close_if_finished(workflow_run)
    end

    test "close_if_finished reports completed_with_failures when a step failed" do
      workflow_run.steps.update_all(state: WorkflowStep.states[:succeeded])
      workflow_run.step(:b).update!(state: :failed)
      Coordinator.close_if_finished(workflow_run)
      assert_equal "completed_with_failures", workflow_run.reload.status
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

    test "claim refuses a step another worker holds, and allows the same jid to resume" do
      step = workflow_run.step(:a)
      assert Coordinator.claim(step.id, token: "jid-1")
      assert_nil Coordinator.claim(step.id, token: "jid-2")
      assert Coordinator.claim(step.id, token: "jid-1")
      assert_equal 0, step.reload.attempts
    end

    test "claim runs a ready step: running, leased, started once" do
      step = workflow_run.step(:a)
      claimed = Coordinator.claim(step.id, token: "jid-1")
      assert_equal ["running", "jid-1"], [claimed.state, claimed.lease_token]
      assert_in_delta step.lease_seconds.seconds.from_now, claimed.lease_expires_at, 5
      assert claimed.started_at
      assert_equal claimed.started_at, Coordinator.claim(step.id, token: "jid-1").started_at
    end

    test "claim refuses a blocked or finished step" do
      assert_nil Coordinator.claim(workflow_run.step(:c).id, token: "t")
      finish(:a, Workflows::Outcome.succeeded("x"))
      assert_nil Coordinator.claim(workflow_run.step(:a).id, token: "t")
    end

    test "a stale worker cannot overwrite a newer attempt" do
      step = workflow_run.step(:a)
      Coordinator.claim(step.id, token: "old")
      step.update_columns(state: WorkflowStep.states[:ready]) # lease reclaimed by recovery
      Coordinator.claim(step.id, token: "new")
      assert_equal [], Coordinator.finish(step, token: "old", outcome: Workflows::Outcome.succeeded("x"))
      assert_equal "running", step.reload.state
      assert_equal [], Coordinator.fail(step, token: "old", error: RuntimeError.new("late"))
      assert_equal ["running", 0], [step.reload.state, step.attempts]
    end

    test "finish records the outcome, merges the result, releases and clears the lease" do
      workflow_run.step(:a).update_columns(result: {"kept" => 1})
      finish(:a, Workflows::Outcome.succeeded("matched", {"qid" => "Q1"}))
      a = workflow_run.step(:a)
      assert_equal ["succeeded", "matched", {"kept" => 1, "qid" => "Q1"}], [a.state, a.outcome, a.result]
      assert_equal [true, true, nil, nil], [a.released?, a.finished_at.present?, a.lease_token, a.lease_expires_at]
    end

    test "finish skipped records the skip" do
      finish(:a, Workflows::Outcome.skipped("not_needed"))
      assert_equal ["skipped", "not_needed", true], workflow_run.step(:a).then { [it.state, it.outcome, it.released?] }
    end

    test "c becomes ready only when a has finished and b is released" do
      finish(:a, Workflows::Outcome.succeeded("matched", {"qid" => "Q1"}))
      assert_equal "blocked", workflow_run.step(:c).reload.state
      ready = finish(:b, Workflows::Outcome.succeeded("done"))
      assert_equal [workflow_run.step(:c).id], ready.map(&:id)
      assert_equal "ready", workflow_run.step(:c).state
    end

    test "advancing twice makes c ready once" do
      finish(:a, Workflows::Outcome.succeeded("x"))
      finish(:b, Workflows::Outcome.succeeded("y"))
      assert_equal [], Coordinator.advance(workflow_run.step(:b))
    end

    test "advance marks edges satisfied" do
      finish(:a, Workflows::Outcome.succeeded("x"))
      edges = workflow_run.step(:c).dependencies.includes(:prerequisite_step).index_by { it.prerequisite_step.key }
      assert edges["a"].satisfied_at
      assert_nil edges["b"].satisfied_at
    end

    test "a release on wait frees release-edge dependents but not finish-edge ones" do
      finish(:a, Workflows::Outcome.succeeded("x"))
      ready = finish(:b, Workflows::Outcome.wait(1.hour.from_now, release: true))
      assert_equal ["waiting", "ready"], [workflow_run.step(:b).reload.state, workflow_run.step(:c).reload.state]
      assert_equal [workflow_run.step(:c).id], ready.map(&:id)
    end

    test "a wait stores run_after and the result, clears the lease, and is not released without release: true" do
      until_time = 1.hour.from_now
      ready = finish(:a, Workflows::Outcome.wait(until_time, result: {"turn" => 2}))
      a = workflow_run.step(:a)
      assert_equal [[], "waiting", {"turn" => 2}, nil, false], [ready, a.state, a.result, a.lease_token, a.released?]
      assert_in_delta until_time, a.run_after, 1
      assert_equal "blocked", workflow_run.step(:c).state
    end

    test "release passes through a blocked finish-edge dependent" do
      finish(:b, Workflows::Outcome.succeeded("y"))
      finish(:a, Workflows::Outcome.wait(1.hour.from_now, release: true))
      assert_equal ["blocked", true], [workflow_run.step(:c).reload.state, workflow_run.step(:c).released?]
    end

    test "release passes down a chain of finish edges in one advance" do
      run = plan_chain
      finish(:x, Workflows::Outcome.wait(1.hour.from_now, release: true), run: run)
      assert_equal [["blocked", true], ["blocked", true]], %i[y z].map { |key| run.step(key).then { [it.state, it.released?] } }
    end

    test "finishing a wait that already released keeps the release time and frees the finish-edge dependent" do
      run = plan_chain
      finish(:x, Workflows::Outcome.wait(1.hour.from_now, release: true), run: run)
      stamp = run.step(:x).released_at
      run.step(:x).update_columns(state: WorkflowStep.states[:ready])
      ready = finish(:x, Workflows::Outcome.succeeded("done"), run: run)
      assert_equal [stamp, ["y"]], [run.step(:x).released_at, ready.map(&:key)]
    end

    test "a dependent that skips itself is advanced in turn, and finishing the last step completes the run" do
      run = plan_chain(options: {skip_y: true})
      ready = finish(:x, Workflows::Outcome.succeeded("done"), run: run)
      assert_equal ["succeeded", "skipped", "ready"], %i[x y z].map { run.step(it).state }
      assert_equal %w[z], ready.map(&:key)
      finish(:z, Workflows::Outcome.succeeded("done"), run: run)
      assert_equal ["completed", true], [run.reload.status, run.finished_at.present?]
    end

    test "finish calls on_terminal with the step and its target, and skips it when the target is gone" do
      finish(:x, Workflows::Outcome.succeeded("done"), run: plan_chain)
      assert_equal [["x", ::Books::Author]], ChainDefinition::TERMINATED

      gone = plan_chain(supersede: true)
      gone.update_columns(enrichable_id: -1)
      finish(:x, Workflows::Outcome.skipped("target_gone"), run: gone)
      assert_equal 1, ChainDefinition::TERMINATED.size
    end

    test "a raising on_terminal callback is swallowed and the dependent still advances" do
      run = plan_chain(options: {raise_terminal: true})
      Rails.logger.expects(:error).with { it.include?("callback boom") }.once
      ready = finish(:x, Workflows::Outcome.succeeded("done"), run: run)
      assert_equal [["succeeded", "ready"], %w[y]], [%i[x y].map { run.step(it).state }, ready.map(&:key)]
    end

    test "fail retries with backoff, then fails and releases" do
      step = workflow_run.step(:a)
      [30, 120].each_with_index do |backoff, index|
        Coordinator.claim(step.id, token: "t")
        assert_equal [], Coordinator.fail(step.reload, token: "t", error: RuntimeError.new("boom"))
        step.reload
        assert_equal ["waiting", index + 1, nil, false], [step.state, step.attempts, step.lease_token, step.released?]
        assert_in_delta backoff.seconds.from_now, step.run_after, 5
        step.update_columns(state: WorkflowStep.states[:ready])
      end
      Coordinator.claim(step.id, token: "t")
      Coordinator.fail(step.reload, token: "t", error: RuntimeError.new("boom"))
      assert_equal ["failed", 3, true, "RuntimeError: boom"], [step.reload.state, step.attempts, step.released?, step.error]
      assert step.finished_at
    end

    test "a failed prerequisite lets its dependent go ahead once the other prerequisites allow" do
      finish(:b, Workflows::Outcome.succeeded("x"))
      step = workflow_run.step(:a)
      step.update_columns(max_attempts: 1)
      Coordinator.claim(step.id, token: "t")
      ready = Coordinator.fail(step.reload, token: "t", error: RuntimeError.new("boom"))
      assert_equal [workflow_run.step(:c).id], ready.map(&:id)
    end

    test "a run whose last open step fails ends completed_with_failures" do
      run = plan_chain
      run.steps.where.not(key: "x").update_all(state: WorkflowStep.states[:skipped])
      step = run.step(:x)
      step.update_columns(max_attempts: 1)
      Coordinator.claim(step.id, token: "t")
      Coordinator.fail(step.reload, token: "t", error: RuntimeError.new("boom"))
      assert_equal "completed_with_failures", run.reload.status
    end

    test "fail truncates a long error message" do
      step = workflow_run.step(:a)
      Coordinator.claim(step.id, token: "t")
      Coordinator.fail(step.reload, token: "t", error: RuntimeError.new("x" * 5000))
      assert_operator step.reload.error.length, :<=, 1000
    end

    test "a wait does not dispatch anything" do
      assert_equal [], finish(:a, Workflows::Outcome.wait(1.minute.from_now))
    end

    test "cancel releases dependents in other runs and returns them ready" do
      other = plan_other_run(waits: {a: [workflow_run.step(:c)]}).data[:run]
      assert_equal "blocked", other.step(:a).state
      ready = Coordinator.cancel(workflow_run, outcome: "target_gone")
      assert_equal ["cancelled", "target_gone"], [workflow_run.reload.status, workflow_run.step(:c).outcome]
      assert_includes ready.map(&:id), other.step(:a).id
      assert_equal "ready", other.step(:a).reload.state
    end

    test "cancel drops a running worker's later finish" do
      step = workflow_run.step(:a)
      Coordinator.claim(step.id, token: "t")
      Coordinator.cancel(workflow_run, outcome: "target_gone")
      assert_equal [], Coordinator.finish(step, token: "t", outcome: Workflows::Outcome.succeeded("late"))
      assert_equal ["skipped", "target_gone"], [step.reload.state, step.outcome]
    end

    test "definition_step looks the key up in the run's definition, and is nil for a key it dropped" do
      assert_equal :a, workflow_run.step(:a).definition_step.key
      assert_nil workflow_run.step(:a).tap { it.key = "gone" }.definition_step
    end
  end
end
