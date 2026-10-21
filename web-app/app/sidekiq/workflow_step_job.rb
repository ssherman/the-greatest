# Runs one workflow step. The message carries only the step id; the step row is
# the source of truth, so a duplicate or stale message claims nothing and
# returns. retry: 0 because the coordinator owns retries (attempts, backoff,
# max_attempts): a Sidekiq retry would run the adapter outside that accounting.
class WorkflowStepJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 0

  def perform(step_id)
    step = Workflows::Coordinator.claim(step_id, token: jid)
    return unless step

    run = step.run
    target = run.enrichable_type.constantize.find_by(id: run.enrichable_id)
    return dispatch(Workflows::Coordinator.cancel(run, outcome: "target_gone")) unless target

    adapter = definition_step(step)&.adapter
    return finish(step, Workflows::Outcome.skipped("unknown_step")) unless adapter

    begin
      outcome = Current.set(workflow_step_id: step.id) { adapter.call(step: step, run: run, target: target) }
    rescue Sidekiq::Shutdown
      # Not a StandardError today, but a shutdown must never be recorded as a
      # step failure: the lease stays with this jid and the pushed-back job
      # claims the step again at once.
      raise
    rescue => e
      return dispatch(Workflows::Coordinator.fail(step, token: jid, error: e))
    end

    finish(step, outcome)
  end

  private

  # A run planned under a workflow that has since been removed is treated like
  # a step key the definition dropped.
  def definition_step(step)
    step.definition_step
  rescue KeyError
    nil
  end

  # Called outside any transaction: the coordinator's exactly-once advance
  # relies on the terminal write committing before it locks the dependents.
  def finish(step, outcome)
    dispatch(Workflows::Coordinator.finish(step, token: jid, outcome: outcome))
  end

  def dispatch(steps)
    Workflows::Dispatcher.dispatch(steps)
  end
end
