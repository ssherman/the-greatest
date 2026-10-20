# Decides what runs next. State lives in the workflow tables, so every method
# here is a conditional update (WHERE state = <what we read>) and safe to call
# twice or from two workers at once.
module Workflows
  module Coordinator
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
          advance(step, run_after)
        elsif edges.all? { |edge| edge.prerequisite_step.released? }
          release(step)
        else
          :blocked
        end
      end

      # Skips every step of the run that has not finished, releasing each so
      # nothing downstream keeps waiting on it, and closes the run.
      def cancel(run, outcome:)
        now = Time.current
        run.steps.where.not(state: WorkflowStep::TERMINAL_STATES).update_all([
          "state = ?, outcome = ?, released_at = COALESCE(released_at, ?), finished_at = ?, " \
          "lease_token = NULL, lease_expires_at = NULL, updated_at = ?",
          WorkflowStep.states[:skipped], outcome, now, now, now
        ])
        run.update!(status: :cancelled, finished_at: now)
      end

      private

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

      def advance(step, run_after)
        reason = skip_reason(step)
        return skip(step, reason) if reason.present?

        if run_after
          claim(step, state: :waiting, run_after: run_after) ? :waiting : :blocked
        else
          claim(step, state: :ready) ? :ready : :blocked
        end
      end

      def skip_reason(step)
        skip_if = Registry.fetch(step.run.workflow).step(step.key)&.skip_if
        skip_if&.call(step.run)
      end

      def skip(step, outcome)
        now = Time.current
        changed = claim(step, state: :skipped, outcome: outcome, finished_at: now,
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
      def claim(step, **attributes)
        WorkflowStep.where(id: step.id, state: :blocked).update_all(attributes.merge(updated_at: Time.current)).positive?
      end

      def resting_state(step)
        %w[ready waiting skipped].include?(step.state) ? step.state.to_sym : :blocked
      end
    end
  end
end
