# frozen_string_literal: true

# A Goodreads-shaped diamond for engine tests: a and b are independent, c
# waits for a to finish and for b to release, and reads a's result. Every
# adapter is a stub that calls TestDefinition.outcomes[key] when one is set
# (it may return an Outcome or raise) and otherwise succeeds.
module Workflows
  class TestDefinition < Workflows::Definition
    QUEUE = :author_chain

    def self.outcomes
      @outcomes ||= {}
    end

    def self.stub_adapter(key)
      lambda do |step:, run:, target:|
        stub = outcomes[key]
        next stub.call(step: step, run: run, target: target) if stub
        result = (key == :c) ? {"from_a" => run.step(:a).result} : {}
        Workflows::Outcome.succeeded("done", result)
      end
    end

    workflow "test.diamond"
    version 1
    target_class ::Books::Author

    add_step key: :a, queue: QUEUE, adapter: stub_adapter(:a)
    add_step key: :b, queue: QUEUE, adapter: stub_adapter(:b)
    add_step key: :c, queue: QUEUE, adapter: stub_adapter(:c), waits_on: {a: :finish, b: :release}
  end

  # Include in a test class: registers TestDefinition for the test and resets
  # its stubbed outcomes afterwards. plan, plan_other_run and workflow_run need
  # Workflows::Planner (built later in the engine); they are late-bound.
  module TestDefinitionHelpers
    extend ActiveSupport::Concern

    included do
      setup { Workflows::Registry.register(Workflows::TestDefinition.workflow, Workflows::TestDefinition) }
      teardown do
        Workflows::Registry.unregister(Workflows::TestDefinition.workflow)
        Workflows::TestDefinition.outcomes.clear
      end
    end

    # Plans a TestDefinition run on King.
    def plan(**planner_args)
      plan_for(books_authors(:king), **planner_args)
    end

    # Plans a TestDefinition run on Tolstoy, cancelling the fixture run first
    # so the one-active-run index does not refuse it.
    def plan_other_run(**planner_args)
      WorkflowRun.where(enrichable: books_authors(:tolstoy), status: :running).find_each do |fixture_run|
        fixture_run.update_columns(status: WorkflowRun.statuses[:cancelled])
      end
      plan_for(books_authors(:tolstoy), **planner_args)
    end

    # The run `plan` creates, planned once per test. Not named `run`: that
    # would override Minitest::Test#run, which the runner calls.
    def workflow_run
      @run ||= plan.data[:run]
    end

    private

    def plan_for(enrichable, **planner_args)
      Workflows::Planner.call(definition: Workflows::TestDefinition, enrichable: enrichable,
        initiated_by: "test", **planner_args)
    end
  end
end
