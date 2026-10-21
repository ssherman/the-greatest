# What needs a person to look at it: the rows behind `bin/rails workflows:stuck`.
#
# It lists OVERDUE work, not old work. A backfill plans tens of thousands of runs
# spaced seconds apart, and a VIAF step can legitimately wait weeks for its turn,
# so "untouched for six hours" would list most of a healthy queue. Each state has
# its own question instead: did the recovery sweep fail to do the one thing it
# does for that state?
#
#   failed    always listed for a week (an exhausted step), whatever its run's status
#   waiting   run_after passed more than `older_than` ago: the sweep did not wake it
#   blocked   every unsatisfied prerequisite is already released (release edge) or
#             terminal (finish edge), so it should have advanced; a step behind a
#             prerequisite that is legitimately still open is not listed
#   ready     not dispatched within the longest redispatch window plus `older_than`
#   running   past its lease: the sweep reclaims these within a minute, so one
#             that stays here means the sweep is not running
module Workflows
  class Stuck
    # A failed step stays interesting for a week; after that it is history.
    FAILED_WINDOW = 7.days

    def self.call(...)
      new(...).call
    end

    def initialize(older_than: 6.hours, now: Time.current)
      @older_than = older_than
      @now = now
    end

    # Rows: {run_id:, workflow:, target:, step:, state:, since:, error:},
    # oldest `since` first.
    def call
      (failed + overdue_waiting + stalled_blocked + undispatched + expired).uniq(&:id)
        .map { |step| row(step) }.sort_by { |row| row[:since] || @now }
    end

    private

    def failed
      scope.failed.where(finished_at: (@now - FAILED_WINDOW)..)
    end

    def overdue_waiting
      scope.waiting.where("workflow_steps.run_after < ?", @now - @older_than)
    end

    # The same test the sweep's re-advance pass uses, inverted: an unsatisfied
    # edge is legitimately open only while its prerequisite has not done what
    # the edge asks. No such edge left means the step should have moved. The age
    # check keeps a step an advance is moving right now off the list.
    def stalled_blocked
      terminal = WorkflowStep.states.values_at(*WorkflowStep::TERMINAL_STATES)
      scope.blocked.where("workflow_steps.updated_at < ?", @now - @older_than).where(<<~SQL.squish, release: WorkflowDependency.kinds[:release], finish: WorkflowDependency.kinds[:finish], terminal: terminal)
        NOT EXISTS (
          SELECT 1 FROM workflow_dependencies d
          JOIN workflow_steps p ON p.id = d.prerequisite_step_id
          WHERE d.step_id = workflow_steps.id AND d.satisfied_at IS NULL
            AND ((d.kind = :release AND p.released_at IS NULL) OR (d.kind = :finish AND p.state NOT IN (:terminal)))
        )
      SQL
    end

    # Past Recovery's longest redispatch window (12 hours), so a step merely
    # waiting out a doubling window behind a deep queue is not listed.
    def undispatched
      scope.ready.where("COALESCE(workflow_steps.dispatched_at, workflow_steps.updated_at) < ?",
        @now - (Recovery::MAX_WINDOW + @older_than))
    end

    def expired
      scope.running.where("workflow_steps.lease_expires_at < ?", @now)
    end

    def scope
      WorkflowStep.includes(:run)
    end

    def row(step)
      {
        run_id: step.workflow_run_id,
        workflow: step.run.workflow,
        target: "#{step.run.enrichable_type} ##{step.run.enrichable_id}",
        step: step.key,
        state: step.state,
        since: since(step),
        error: step.error
      }
    end

    # When the step became overdue (or, for a failed step, when it failed).
    def since(step)
      case step.state
      when "failed" then step.finished_at || step.updated_at
      when "waiting" then step.run_after
      when "running" then step.lease_expires_at
      when "ready" then step.dispatched_at || step.updated_at
      else step.updated_at
      end
    end
  end
end
