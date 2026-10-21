# Decides what runs next. State lives in the workflow tables, so every method
# here is a conditional update (WHERE state = <what we read>) and safe to call
# twice or from two workers at once.
module Workflows
  module Coordinator
    FAILURE_BACKOFF = 30.seconds
    MAX_ERROR_LENGTH = 1_000
    LEASE_EXPIRED = "lease expired"

    class << self
      # Looks at one blocked step and acts on it. Returns:
      #   :ready     every edge is satisfied; the step moved to ready
      #   :waiting   every edge is satisfied but the step must wait until run_after
      #   :skipped   every edge is satisfied and its skip_if said to skip it
      #   :released  edges are open but every prerequisite is released, so the step
      #              is released too (it stays blocked; spec section 5)
      #   :blocked   nothing to do: edges still open, already released, or the step
      #              is not blocked any more
      # A step that already advanced to ready, waiting or skipped reports that
      # state, so a second call returns the same answer without writing.
      #
      # skip_if runs only here, when the edges are all satisfied, and never
      # dispatches the step: a step that will be skipped must not queue behind a
      # backlog just to say so.
      def evaluate(step, run_after: nil)
        step.reload
        return resting_state(step) unless step.blocked?

        edges = step.dependencies.includes(:prerequisite_step).to_a
        record_satisfied(edges)

        if edges.all? { |edge| satisfied?(edge) }
          settle_ready(step, run_after)
        elsif edges.all? { |edge| edge.prerequisite_step.released? }
          release(step)
        else
          :blocked
        end
      end

      # Takes a ready step for one worker. One conditional UPDATE: allowed from
      # ready, or from running when the token is the same (a pushed-back job
      # resuming without waiting out its lease). Does not touch attempts: only
      # failures and expired leases use one. Returns the step, or nil when
      # another worker holds it or it is not runnable.
      def claim(step_id, token:)
        now = Time.current
        binds = {running: running_state, ready: ready_state, id: step_id, token: token, now: now}
        sql = WorkflowStep.sanitize_sql_array([<<~SQL, binds])
          UPDATE workflow_steps
          SET state = :running, lease_token = :token,
              lease_expires_at = :now::timestamp + lease_seconds * INTERVAL '1 second',
              started_at = COALESCE(started_at, :now), updated_at = :now
          WHERE id = :id AND (state = :ready OR (state = :running AND lease_token = :token))
          RETURNING *
        SQL
        WorkflowStep.find_by_sql(sql).first
      end

      # Records what a worker's adapter returned, only if the worker still holds
      # the lease: a stale worker's write is dropped. Returns the steps that
      # became ready, for the caller to dispatch after commit; it never
      # dispatches itself. A waiting step is never in that list, since only the
      # recovery sweep wakes it.
      def finish(step, token:, outcome:)
        case outcome.kind
        when :succeeded, :skipped then finish_terminal(step, token, outcome)
        when :wait then finish_wait(step, token, outcome)
        else raise ArgumentError, "unknown outcome kind #{outcome.kind.inspect}"
        end
      end

      # A raised error: retry later with backoff (30 s, 2 min, 8 min), or fail
      # the step for good at max_attempts. Token-guarded like finish. One
      # statement decides retry or fail from the row's own counters, so two
      # callers cannot disagree about which attempt this was.
      def fail(step, token:, error:)
        message = "#{error.class}: #{error.message}".delete("\u0000").truncate(MAX_ERROR_LENGTH)
        binds = {running: running_state, id: step.id, token: token, now: Time.current, error: message,
                 waiting: WorkflowStep.states[:waiting], failed: WorkflowStep.states[:failed],
                 backoff: FAILURE_BACKOFF.to_i}
        sql = WorkflowStep.sanitize_sql_array([<<~SQL, binds])
          UPDATE workflow_steps
          SET attempts = attempts + 1, error = :error,
              state = CASE WHEN attempts + 1 >= max_attempts THEN :failed ELSE :waiting END,
              run_after = CASE WHEN attempts + 1 >= max_attempts THEN run_after
                               ELSE :now::timestamp + :backoff * power(4, attempts) * INTERVAL '1 second' END,
              finished_at = CASE WHEN attempts + 1 >= max_attempts THEN :now ELSE finished_at END,
              released_at = CASE WHEN attempts + 1 >= max_attempts THEN COALESCE(released_at, :now) ELSE released_at END,
              lease_token = NULL, lease_expires_at = NULL, updated_at = :now
          WHERE id = :id AND state = :running AND lease_token = :token
          RETURNING *
        SQL
        failed = WorkflowStep.find_by_sql(sql).first
        return [] unless failed&.failed?

        settle_terminal(failed)
      end

      # The recovery sweep's counterpart to fail: a worker that held the lease
      # is gone (crash, deploy, lost connection), so the expiry itself is the
      # failed attempt. Below max_attempts the step goes straight back to ready
      # (no backoff: nothing raised, and the worker may simply have been killed)
      # with dispatched_at cleared so the sweep dispatches it in the same pass;
      # at max_attempts it fails, released, and its dependents advance. As in a
      # sweep, on_terminal is not called. Conditional on the lease still being
      # expired, so a worker that finishes at the same moment either wins (this
      # returns nil, nothing written) or loses cleanly (its token-guarded write
      # is dropped). Returns nil when nothing was reclaimed, else the steps that
      # became ready: the step itself, or the dependents of a failed one.
      def expire_lease(step, now: Time.current)
        binds = {running: running_state, ready: ready_state, failed: WorkflowStep.states[:failed],
                 id: step.id, now: now, error: LEASE_EXPIRED}
        sql = WorkflowStep.sanitize_sql_array([<<~SQL, binds])
          UPDATE workflow_steps
          SET attempts = attempts + 1, error = :error,
              state = CASE WHEN attempts + 1 >= max_attempts THEN :failed ELSE :ready END,
              finished_at = CASE WHEN attempts + 1 >= max_attempts THEN :now ELSE finished_at END,
              released_at = CASE WHEN attempts + 1 >= max_attempts THEN COALESCE(released_at, :now) ELSE released_at END,
              dispatched_at = NULL, dispatch_count = 0,
              lease_token = NULL, lease_expires_at = NULL, updated_at = :now
          WHERE id = :id AND state = :running AND lease_expires_at < :now
          RETURNING *
        SQL
        expired = WorkflowStep.find_by_sql(sql).first
        return unless expired

        expired.failed? ? advance(expired) : [expired]
      end

      # Moves the dependents of a step forward after it finished or was
      # released. For each edge on the step: record it satisfied, then evaluate
      # the dependent. Each dependent row is locked FOR UPDATE (in id order, so
      # two advances take locks in the same order) and its edges are read after
      # the lock, so a concurrent advance is a no-op: the step becomes ready
      # exactly once. A dependent that comes out skipped, or released without
      # running, is advanced in turn from a work list. Finally every run touched
      # that has no open step left is closed. Returns the steps that became ready.
      def advance(step)
        ready = []
        run_ids = Set[step.workflow_run_id]
        ActiveRecord::Base.transaction do
          pending = [step.id]
          until pending.empty?
            dependent_ids = WorkflowDependency.where(prerequisite_step_id: pending.shift).distinct.pluck(:step_id)
            WorkflowStep.where(id: dependent_ids).order(:id).lock.each do |dependent|
              run_ids << dependent.workflow_run_id
              record_satisfied(dependent.dependencies.includes(:prerequisite_step).to_a)
              next unless dependent.blocked?

              case evaluate(dependent)
              when :ready then ready << dependent
              when :skipped, :released then pending << dependent.id
              end
            end
          end
          WorkflowRun.where(id: run_ids.to_a).find_each { |run| close_if_finished(run) }
        end
        ready
      end

      # Skips every step of the run that has not finished, releasing each so
      # nothing downstream keeps waiting on it, and closes the run. Dependents in
      # other runs are advanced; returns the ones that became ready.
      def cancel(run, outcome:)
        ready = []
        ActiveRecord::Base.transaction do
          open_steps = run.steps.where.not(state: WorkflowStep::TERMINAL_STATES).order(:id).lock.to_a
          now = Time.current
          WorkflowStep.where(id: open_steps.map(&:id)).update_all([
            "state = ?, outcome = ?, released_at = COALESCE(released_at, ?), finished_at = ?, " \
            "lease_token = NULL, lease_expires_at = NULL, updated_at = ?",
            WorkflowStep.states[:skipped], outcome, now, now, now
          ])
          # Cancelled before advancing, so closing the touched runs cannot mark it completed.
          run.update!(status: :cancelled, finished_at: now)
          open_steps.each { |open_step| ready.concat(advance(open_step)) }
        end
        ready.uniq(&:id)
      end

      # Closes a run whose steps are all terminal: completed_with_failures when
      # any failed, else completed. Conditional on the run still being running, so
      # a second caller changes nothing. Returns true when this call closed it.
      def close_if_finished(run)
        states = run.steps.pluck(:state)
        return false if states.empty? || states.any? { |state| !WorkflowStep::TERMINAL_STATES.include?(state) }

        status = states.include?("failed") ? :completed_with_failures : :completed
        WorkflowRun.where(id: run.id, status: :running).update_all(status: WorkflowRun.statuses[status],
          finished_at: Time.current, updated_at: Time.current).positive?
      end

      private

      def running_state = WorkflowStep.states[:running]

      def ready_state = WorkflowStep.states[:ready]

      def finish_terminal(step, token, outcome)
        now = Time.current
        updated = held(step, token).update_all([
          "state = ?, outcome = ?, result = result || ?::jsonb, finished_at = ?, " \
          "released_at = COALESCE(released_at, ?), lease_token = NULL, lease_expires_at = NULL, updated_at = ?",
          WorkflowStep.states[outcome.kind], outcome.outcome, outcome.result.to_json, now, now, now
        ])
        return [] if updated.zero?

        settle_terminal(step.reload)
      end

      # A wait keeps the step alive, so it is not released unless it asks to be.
      # Only a release that actually happened now advances dependents.
      def finish_wait(step, token, outcome)
        now = Time.current
        released = false
        ActiveRecord::Base.transaction do
          updated = held(step, token).update_all([
            "state = ?, run_after = ?, result = result || ?::jsonb, lease_token = NULL, " \
            "lease_expires_at = NULL, updated_at = ?",
            WorkflowStep.states[:waiting], outcome.run_after, outcome.result.to_json, now
          ])
          if updated.positive? && outcome.release
            released = WorkflowStep.where(id: step.id, released_at: nil).update_all(released_at: now, updated_at: now).positive?
          end
        end
        released ? advance(step.reload) : []
      end

      # The step, but only while this worker still holds its lease.
      def held(step, token)
        WorkflowStep.where(id: step.id, state: :running, lease_token: token)
      end

      # A step just became terminal: tell its definition, then advance. The
      # callback is a side effect (a cache purge, a ledger note), never a gate:
      # one that raises is logged and swallowed, so the dependents still move.
      # on_terminal fires only here, when a worker finishes or fails the step;
      # a step skipped by skip_if, cancelled, or swept never calls it.
      def settle_terminal(step)
        begin
          run_on_terminal(step)
        rescue => e
          Rails.logger.error("Workflows::Coordinator: on_terminal raised for step #{step.id}: #{e.class}: #{e.message}")
        end
        advance(step)
      end

      def run_on_terminal(step)
        callback = step.definition_step&.on_terminal
        return unless callback

        run = step.run
        target = run.enrichable_type.constantize.find_by(id: run.enrichable_id)
        callback.call(step, target) if target
      end

      # A finish edge needs its prerequisite to be terminal; a release edge only
      # needs it released. The stored satisfied_at wins: once satisfied, an edge
      # stays satisfied.
      def satisfied?(edge)
        return true if edge.satisfied_at

        prerequisite = edge.prerequisite_step
        edge.finish? ? prerequisite.terminal? : prerequisite.released?
      end

      def record_satisfied(edges)
        newly = edges.select { |edge| edge.satisfied_at.nil? && satisfied?(edge) }
        return if newly.empty?

        now = Time.current
        WorkflowDependency.where(id: newly.map(&:id), satisfied_at: nil).update_all(satisfied_at: now, updated_at: now)
        newly.each { |edge| edge.satisfied_at = now }
      end

      def settle_ready(step, run_after)
        reason = skip_reason(step)
        return skip(step, reason) if reason.present?

        if run_after
          transition(step, state: :waiting, run_after: run_after) ? :waiting : :blocked
        else
          transition(step, state: :ready) ? :ready : :blocked
        end
      end

      def skip_reason(step)
        step.definition_step&.skip_if&.call(step.run)
      end

      def skip(step, outcome)
        now = Time.current
        changed = transition(step, state: :skipped, outcome: outcome, finished_at: now,
          released_at: step.released_at || now)
        changed ? :skipped : :blocked
      end

      def release(step)
        return :blocked if step.released?

        now = Time.current
        released = WorkflowStep.where(id: step.id, state: :blocked, released_at: nil)
          .update_all(released_at: now, updated_at: now)
        released.zero? ? :blocked : :released
      end

      # The conditional update every transition goes through. True when this
      # call made the change, false when someone else already moved the step.
      def transition(step, **attributes)
        WorkflowStep.where(id: step.id, state: :blocked).update_all(attributes.merge(updated_at: Time.current)).positive?
      end

      def resting_state(step)
        %w[ready waiting skipped].include?(step.state) ? step.state.to_sym : :blocked
      end
    end
  end
end
