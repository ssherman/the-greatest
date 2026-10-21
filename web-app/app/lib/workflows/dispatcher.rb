# Puts ready steps on their Sidekiq queues. The one seam between the workflow
# tables and Sidekiq: planner and coordinator callers hand it the steps that
# became ready, and tests stub `dispatch` to plan without running anything.
#
# A dispatch is only a nudge. If it is lost (Redis down, a crash between the
# commit and the enqueue) the step is still `ready` in Postgres, with an old or
# missing dispatched_at, and the recovery sweep enqueues it again.
module Workflows
  module Dispatcher
    class << self
      # Enqueues each step that is ready now. Readiness is read from the
      # database: the steps the coordinator returns are in-memory rows from
      # before their update_all, and a step claimed by a worker in the meantime
      # must not be queued again. Never raises: any failure on one step (a Redis
      # outage, a pool timeout, a database error in the counter update) is logged
      # and leaves that step's dispatched_at alone, which is exactly what the
      # sweep looks for. The caller's transaction has already committed, so an
      # error here would only turn a finished write into an exception.
      def dispatch(steps)
        Array(steps).each do |step|
          current = WorkflowStep.find_by(id: step.id)
          enqueue(current) if current&.ready?
        end
      end

      # For callers inside a transaction: the job must not run (and find the
      # step still blocked) before the transaction that readied it commits.
      def after_commit(steps)
        ActiveRecord.after_all_transactions_commit { dispatch(steps) }
      end

      private

      def enqueue(step)
        WorkflowStepJob.set(queue: step.queue).perform_async(step.id)
        WorkflowStep.where(id: step.id).update_all(["dispatched_at = ?, dispatch_count = dispatch_count + 1", Time.current])
      rescue => e
        Rails.logger.error("Workflows::Dispatcher: could not enqueue step #{step.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
