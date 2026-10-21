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

    def stuck_keys(**args)
      Workflows::Stuck.call(**args).map { it[:step] }.sort
    end

    test "lists a waiting step the sweep failed to wake and a running step past its lease" do
      set(:a, state: :waiting, run_after: 7.hours.ago)
      set(:b, state: :running, lease_expires_at: 1.minute.ago)
      assert_equal %w[a b], stuck_keys
    end

    test "does not list a waiting step whose time has not come" do
      set(:a, state: :waiting, run_after: 30.days.from_now, updated_at: 30.days.ago)
      assert_empty stuck_keys
    end

    test "does not list a waiting step that is only recently due" do
      set(:a, state: :waiting, run_after: 5.hours.ago)
      assert_empty stuck_keys
    end

    test "does not list a running step within its lease" do
      set(:b, state: :running, lease_expires_at: 1.minute.from_now)
      assert_empty stuck_keys
    end

    test "honours a custom grace period" do
      set(:a, state: :waiting, run_after: 2.hours.ago)
      assert_includes stuck_keys(older_than: 1.hour), "a"
      refute_includes stuck_keys(older_than: 3.hours), "a"
    end

    test "does not list a blocked step behind a prerequisite that is legitimately still open" do
      # c waits on a (finish) and b (release); both are ready, so c is rightly blocked.
      workflow_run.steps.update_all(updated_at: 7.hours.ago)
      assert_equal "blocked", workflow_run.step(:c).state
      assert_empty stuck_keys
    end

    test "does not list a blocked step behind a legitimately waiting prerequisite" do
      workflow_run.steps.update_all(updated_at: 30.days.ago, dispatched_at: 1.minute.ago)
      set(:a, state: :waiting, run_after: 30.days.from_now)
      assert_empty stuck_keys
    end

    test "lists a blocked step whose prerequisites are terminal or released but that never advanced" do
      set(:a, state: :succeeded, finished_at: 8.hours.ago, released_at: 8.hours.ago)
      set(:b, state: :running, released_at: 8.hours.ago, lease_expires_at: 1.hour.from_now)
      workflow_run.step(:c).update_columns(updated_at: 7.hours.ago)
      assert_equal %w[c], stuck_keys
    end

    test "does not list a blocked step behind a finish edge on a released but still running prerequisite" do
      set(:a, state: :running, released_at: 8.hours.ago, lease_expires_at: 1.hour.from_now)
      set(:b, state: :succeeded, finished_at: 8.hours.ago, released_at: 8.hours.ago)
      workflow_run.step(:c).update_columns(updated_at: 7.hours.ago)
      assert_empty stuck_keys
    end

    test "lists a ready step only beyond the longest redispatch window" do
      set(:a, dispatched_at: 12.hours.ago - 1.hour)
      set(:b, dispatched_at: 18.hours.ago - 1.minute)
      assert_equal %w[b], stuck_keys
    end

    test "lists a failed step with its error, even in a run that is still running" do
      set(:a, state: :failed, error: "boom", finished_at: 1.day.ago)
      row = Workflows::Stuck.call.find { it[:step] == "a" }
      assert_equal ["boom", workflow_run.id, "failed", "running"], [row[:error], row[:run_id], row[:state], workflow_run.reload.status]
    end

    test "ignores a failed step that failed more than a week ago" do
      set(:a, state: :failed, error: "boom", finished_at: 8.days.ago)
      assert_empty stuck_keys
    end

    test "ignores steps that are done" do
      set(:a, state: :succeeded, updated_at: 10.days.ago, finished_at: 10.days.ago)
      assert_empty stuck_keys
    end

    test "describes the workflow and the target" do
      set(:a, state: :waiting, run_after: 7.hours.ago)
      row = Workflows::Stuck.call.find { it[:step] == "a" }
      assert_equal ["test.diamond", "Books::Author ##{books_authors(:king).id}"], [row[:workflow], row[:target]]
    end
  end
end
