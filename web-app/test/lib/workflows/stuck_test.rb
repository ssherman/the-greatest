require "test_helper"

module Workflows
  class StuckTest < ActiveSupport::TestCase
    include Workflows::TestDefinitionHelpers
    include Workflows::DispatchHelper

    setup do
      # The fixture run's ready step would otherwise count once it is old.
      WorkflowRun.where(enrichable: books_authors(:tolstoy), status: :running).find_each do |fixture_run|
        Coordinator.cancel(fixture_run, outcome: "test")
      end
      stub_workflow_dispatch
    end

    def set(key, **columns)
      state = columns.delete(:state)
      columns[:state] = WorkflowStep.states[state] if state
      workflow_run.step(key).update_columns(columns)
    end

    test "lists a step waiting longer than the threshold and a running step past its lease" do
      set(:a, state: :waiting, updated_at: 7.hours.ago)
      set(:b, state: :running, lease_expires_at: 1.minute.ago)
      assert_equal %w[a b], Workflows::Stuck.call.map { it[:step] }.select { |key| %w[a b].include?(key) }.sort
    end

    test "leaves out recent waiting steps and running steps within their lease" do
      set(:a, state: :waiting, updated_at: 5.hours.ago)
      set(:b, state: :running, lease_expires_at: 1.minute.from_now)
      assert_empty Workflows::Stuck.call.map { it[:step] }
    end

    test "honours a custom threshold" do
      set(:a, state: :waiting, updated_at: 2.hours.ago)
      assert_includes Workflows::Stuck.call(older_than: 1.hour).map { it[:step] }, "a"
      refute_includes Workflows::Stuck.call(older_than: 3.hours).map { it[:step] }, "a"
    end

    test "lists an old blocked step and an old ready step" do
      workflow_run.steps.update_all(updated_at: 7.hours.ago)
      states = Workflows::Stuck.call.to_h { [it[:step], it[:state]] }
      assert_equal({"a" => "ready", "b" => "ready", "c" => "blocked"}, states)
    end

    test "lists a failed step of a run that finished within a week, with its error" do
      set(:a, state: :failed, error: "boom", finished_at: 1.day.ago)
      workflow_run.update_columns(finished_at: 1.day.ago)
      row = Workflows::Stuck.call.find { it[:step] == "a" }
      assert_equal ["boom", workflow_run.id, "failed"], [row[:error], row[:run_id], row[:state]]
    end

    test "ignores a failed step of a run that finished long ago" do
      set(:a, state: :failed, error: "boom", finished_at: 8.days.ago)
      workflow_run.update_columns(finished_at: 8.days.ago)
      assert_empty Workflows::Stuck.call
    end

    test "ignores steps that are done" do
      set(:a, state: :succeeded, updated_at: 10.days.ago, finished_at: 10.days.ago)
      assert_empty Workflows::Stuck.call
    end

    test "describes the workflow and the target" do
      set(:a, state: :waiting, updated_at: 7.hours.ago)
      row = Workflows::Stuck.call.find { it[:step] == "a" }
      assert_equal ["test.diamond", "Books::Author ##{books_authors(:king).id}"], [row[:workflow], row[:target]]
    end
  end
end
