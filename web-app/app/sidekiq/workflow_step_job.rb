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

    adapter = step.definition_step&.adapter
    return finish(step, Workflows::Outcome.skipped("unknown_step")) unless adapter

    begin
      outcome = Current.set(workflow_step_id: step.id) { adapter.call(step: step, run: run, target: target) }
      # Inside the rescue so an adapter that returns something other than an
      # Outcome is recorded as an attempt instead of leaving the step to wait
      # out its lease. After a committed terminal write fail is a no-op: it is
      # guarded on the step still being running under this token.
      finish(step, outcome)
    rescue Sidekiq::Shutdown
      # Not a StandardError today, but a shutdown must never be recorded as a
      # step failure: the lease stays with this jid and the pushed-back job
      # claims the step again at once.
      raise
    rescue => e
      # Logged first: when the error came from finish after its terminal write
      # committed, fail is a no-op and this line is the only trace of it.
      Rails.logger.error("WorkflowStepJob: step #{step.id} raised #{e.class}: #{e.message}")
      dispatch(Workflows::Coordinator.fail(step, token: jid, error: e))
    end
  end

  private

  # Called outside any transaction: the coordinator's exactly-once advance
  # relies on the terminal write committing before it locks the dependents.
  def finish(step, outcome)
    dispatch(Workflows::Coordinator.finish(step, token: jid, outcome: outcome))
  end

  def dispatch(steps)
    Workflows::Dispatcher.dispatch(steps)
  end
end
