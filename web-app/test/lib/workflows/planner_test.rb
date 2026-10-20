require "test_helper"

module Workflows
  class PlannerTest < ActiveSupport::TestCase
    include Workflows::TestDefinitionHelpers

    class SkipDefinition < Workflows::Definition
      workflow "test.skippable"
      version 1
      target_class ::Books::Author

      add_step key: :first, queue: :author_chain, adapter: ->(**) {}
      add_step key: :maybe, queue: :author_chain, adapter: ->(**) {}, waits_on: {first: :finish},
        skip_if: ->(run) { run.options["skip_maybe"] ? "not_needed" : nil }
      add_step key: :last, queue: :author_chain, adapter: ->(**) {}, waits_on: {maybe: :finish}
    end

    setup { Workflows::Registry.register("test.skippable", SkipDefinition) }
    teardown { Workflows::Registry.unregister("test.skippable") }

    test "plans every step, with a and b ready and c blocked on both" do
      run = plan.data[:run]
      assert_equal({"a" => "ready", "b" => "ready", "c" => "blocked"}, run.steps.pluck(:key, :state).to_h)
      assert_equal [["a", "finish"], ["b", "release"]], run.step(:c).dependencies.map { [it.prerequisite_step.key, it.kind] }.sort
    end

    test "copies the definition's version and each step's queue, attempts and lease" do
      result = plan(options: {"note" => "x"})
      run = result.data[:run]
      assert_equal [1, "test", {"note" => "x"}], [run.definition_version, run.initiated_by, run.options]
      assert_equal ["author_chain", 3, 600], run.step(:a).then { [it.queue, it.max_attempts, it.lease_seconds] }
      assert_equal [true, [run.step(:a), run.step(:b)]], [result.success?, result.data[:ready_steps]]
    end

    test "returns the active run instead of planning a second one" do
      first = plan.data[:run]
      second = plan
      assert_equal [first.id, true, []], [second.data[:run].id, second.data[:reused], second.data[:ready_steps]]
      assert_equal 3, WorkflowStep.where(workflow_run_id: first.id).count
    end

    test "supersede cancels the active run and plans a new one" do
      first = plan.data[:run]
      second = plan(supersede: true).data[:run]
      assert_equal ["cancelled", "superseded"], [first.reload.status, first.step(:a).outcome]
      refute_equal first.id, second.id
      assert_equal "running", second.status
    end

    test "only: skips the unrequested steps as not_requested, releasing them" do
      run = plan(options: {only: ["a"]}).data[:run]
      assert_equal ["skipped", "not_requested", true], [run.step(:b).state, run.step(:b).outcome, run.step(:b).released?]
    end

    test "only: a skipped release prerequisite counts as satisfied for its dependent" do
      run = plan(options: {only: ["a", "c"]}).data[:run]
      assert_equal({"a" => "ready", "b" => "skipped", "c" => "blocked"}, run.steps.pluck(:key, :state).to_h)
      assert run.step(:c).dependencies.find_by(kind: :release).satisfied_at
    end

    test "only: that skips a finish prerequisite lets the dependent run at plan time" do
      run = plan(options: {only: ["c"]}).data[:run]
      assert_equal({"a" => "skipped", "b" => "skipped", "c" => "ready"}, run.steps.pluck(:key, :state).to_h)
    end

    test "start_at: skips the steps before it" do
      run = plan(options: {start_at: "b"}).data[:run]
      assert_equal %w[skipped ready], [run.step(:a).state, run.step(:b).state]
      assert_equal "not_requested", run.step(:a).outcome
    end

    test "skips: plans the named steps skipped with the given outcome" do
      run = plan(skips: {b: "no_authors"}).data[:run]
      assert_equal ["skipped", "no_authors", true], [run.step(:b).state, run.step(:b).outcome, run.step(:b).released?]
      assert_equal "ready", run.step(:a).state
    end

    test "a cross-run wait on an already released step is satisfied at plan time" do
      other = workflow_steps(:tolstoy_wikidata).tap { it.update!(state: :succeeded, released_at: Time.current) }
      run = plan(waits: {a: [other]}).data[:run]
      assert_equal "ready", run.step(:a).state
      assert_equal [["release", true]], run.step(:a).dependencies.map { [it.kind, it.satisfied_at.present?] }
    end

    test "a cross-run wait on an unreleased step keeps the step blocked" do
      other = workflow_steps(:tolstoy_wikidata)
      run = plan(waits: {a: [other]}).data[:run]
      assert_equal ["blocked", "ready"], [run.step(:a).state, run.step(:b).state]
      assert_equal [false], run.step(:a).dependencies.map { it.satisfied_at.present? }
    end

    test "start_after leaves the first steps waiting until then" do
      freeze_time do
        run = plan(start_after: 10.seconds.from_now).data[:run]
        assert_equal ["waiting", 10.seconds.from_now.to_i], [run.step(:a).state, run.step(:a).run_after.to_i]
        assert_equal "blocked", run.step(:c).state
      end
    end

    test "start_after returns no ready steps" do
      assert_empty plan(start_after: 1.minute.from_now).data[:ready_steps]
    end

    test "an unknown step key in options, skips or waits is refused and plans nothing" do
      [{options: {only: ["nope"]}}, {options: {start_at: "nope"}}, {skips: {nope: "x"}}, {waits: {nope: []}}].each do |args|
        result = plan(**args)
        assert_equal [false, 0], [result.success?, WorkflowRun.where(workflow: "test.diamond").count], args.inspect
        assert_match(/nope/, result.errors.join)
      end
    end

    test "a target of the wrong class is refused" do
      result = Workflows::Planner.call(definition: Workflows::TestDefinition, enrichable: books_books(:war_and_peace), initiated_by: "test")
      assert_equal [false, 0], [result.success?, WorkflowRun.where(workflow: "test.diamond").count]
    end

    test "a rolled-back caller transaction leaves no run" do
      ActiveRecord::Base.transaction do
        plan
        raise ActiveRecord::Rollback
      end
      assert_equal 0, WorkflowRun.where(workflow: "test.diamond").count
    end

    test "skip_if is evaluated once a step's prerequisites are satisfied, and a skip frees the next step" do
      run = plan_skippable(options: {skip_maybe: true, only: %w[maybe last]}).data[:run]
      assert_equal({"first" => "skipped", "maybe" => "skipped", "last" => "ready"}, run.steps.pluck(:key, :state).to_h)
      assert_equal "not_needed", run.step(:maybe).outcome
    end

    test "skip_if is not evaluated while a prerequisite is open, and a nil lets the step run" do
      run = plan_skippable(options: {skip_maybe: true}).data[:run]
      assert_equal({"first" => "ready", "maybe" => "blocked", "last" => "blocked"}, run.steps.pluck(:key, :state).to_h)
      run = plan_skippable(options: {only: %w[maybe last]}, supersede: true).data[:run]
      assert_equal({"first" => "skipped", "maybe" => "ready", "last" => "blocked"}, run.steps.pluck(:key, :state).to_h)
    end

    private

    def plan_skippable(options: {}, **args)
      Workflows::Planner.call(definition: SkipDefinition, enrichable: books_authors(:king), initiated_by: "test",
        options: options, **args)
    end
  end
end
