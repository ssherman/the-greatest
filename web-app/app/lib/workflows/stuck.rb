# What needs a person to look at it: the rows behind `bin/rails workflows:stuck`.
# The recovery sweep fixes most trouble on its own, so a row here is either a
# step that has genuinely run out of attempts or one the sweep has not moved for
# hours.
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
      (failed + idle + expired).uniq(&:id).map { |step| row(step) }.sort_by { |row| row[:since] || @now }
    end

    private

    def failed
      scope.failed.where(workflow_runs: {finished_at: (@now - FAILED_WINDOW)..})
    end

    # waiting, blocked and ready are all "should be moving"; an untouched row
    # means the sweep could not move it either (a prerequisite that never
    # finishes, a redispatch window capped at 12 hours).
    def idle
      scope.where(state: %i[waiting blocked ready]).where("workflow_steps.updated_at < ?", @now - @older_than)
    end

    def expired
      scope.running.where("workflow_steps.lease_expires_at < ?", @now)
    end

    def scope
      WorkflowStep.joins(:run).includes(:run)
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

    def since(step)
      case step.state
      when "failed" then step.finished_at || step.updated_at
      when "running" then step.lease_expires_at
      else step.updated_at
      end
    end
  end
end
