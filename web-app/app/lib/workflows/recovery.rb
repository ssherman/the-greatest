# The every-minute sweep that makes the workflow tables self-healing. Nothing
# else in the engine has to survive a crash: a lost Sidekiq message, a worker
# killed mid-step, an advance interrupted between two writes, or a deleted
# target all leave rows in states that one of these passes recognises.
#
# Passes run in this order, each limited to `batch` rows and each independent:
# one that raises is logged and the next still runs, so one bad row cannot stop
# the whole sweep. Every pass is a conditional update or goes through the
# coordinator, so a sweep that overlaps a worker (or another sweep) is safe.
#
#   1. cancel    running runs whose target row is gone
#   2. reclaim   running steps whose lease expired
#   3. wake      waiting steps whose run_after has passed
#   4. readvance edges that are satisfiable but were never recorded
#   5. close     running runs whose steps are all terminal
#   6. dispatch  ready steps whose enqueue was lost or whose window lapsed
#
# Dispatch is last because the earlier passes make steps ready (cancelling
# releases a book step waiting on the author; waking and reclaiming ready the
# step itself), and they leave dispatched_at empty so this pass enqueues them
# in the same sweep rather than a window later.
module Workflows
  class Recovery
    # How long a ready step may sit after a dispatch before the sweep assumes the
    # message was lost and enqueues it again. Doubles with every dispatch so a
    # step queued behind a long backlog is not re-sent forever.
    BASE_WINDOW = 10.minutes
    MAX_WINDOW = 12.hours

    def self.call(...)
      new(...).call
    end

    def initialize(now: Time.current, batch: 1_000)
      @now = now
      @batch = batch
    end

    def call
      {
        cancelled: pass(:cancel_orphans),
        reclaimed: pass(:reclaim_expired_leases),
        woken: pass(:wake_waiting_steps),
        readvanced: pass(:readvance_edges),
        closed: pass(:close_finished_runs),
        redispatched: pass(:redispatch_ready_steps)
      }
    end

    private

    # A failed pass counts as zero rather than raising into the job: the next
    # minute's sweep retries it.
    def pass(name)
      send(name)
    rescue => e
      Rails.logger.error("Workflows::Recovery: #{name} failed: #{e.class}: #{e.message}")
      0
    end

    # Runs the block for each row, counting the ones that return truthy. A row
    # that raises is logged and skipped so the rest of the batch still runs.
    def each_row(name, rows)
      rows.count do |row|
        yield row
      rescue => e
        Rails.logger.error("Workflows::Recovery: #{name} failed for #{row.class.name} #{row.id}: #{e.class}: #{e.message}")
        false
      end
    end

    def cancel_orphans
      remaining = @batch
      cancelled = 0
      WorkflowRun.running.distinct.pluck(:enrichable_type).each do |type|
        break if remaining <= 0

        orphans = orphaned_runs(type, remaining)
        remaining -= orphans.size
        cancelled += each_row(:cancel_orphans, orphans) do |run|
          Coordinator.cancel(run, outcome: "target_gone")
          true
        end
      end
      cancelled
    end

    # Per enrichable_type, because each type has its own table. The type comes
    # from our own rows and the table name is quoted, so it is safe to build the
    # join from it. A type whose class no longer exists is logged and skipped.
    def orphaned_runs(type, limit)
      target = type.safe_constantize
      unless target.respond_to?(:table_name)
        Rails.logger.error("Workflows::Recovery: cancel_orphans: unknown enrichable_type #{type}")
        return []
      end

      table = WorkflowRun.connection.quote_table_name(target.table_name)
      key = WorkflowRun.connection.quote_column_name(target.primary_key)
      WorkflowRun.running.where(enrichable_type: type)
        .joins("LEFT JOIN #{table} ON #{table}.#{key} = workflow_runs.enrichable_id")
        .where("#{table}.#{key} IS NULL").order(:id).limit(limit).to_a
    end

    def reclaim_expired_leases
      steps = WorkflowStep.running.where("lease_expires_at < ?", @now).order(:lease_expires_at).limit(@batch).to_a
      each_row(:reclaim_expired_leases, steps) { |step| !Coordinator.expire_lease(step, now: @now).nil? }
    end

    # Cleared dispatched_at and dispatch_count make the dispatch pass enqueue it
    # now: a step that waited out a rate limit is due, not "recently dispatched".
    def wake_waiting_steps
      ids = WorkflowStep.waiting.where("run_after <= ?", @now).order(:run_after).limit(@batch).pluck(:id)
      WorkflowStep.where(id: ids, state: :waiting).where("run_after <= ?", @now)
        .update_all(state: WorkflowStep.states[:ready], dispatched_at: nil, dispatch_count: 0, updated_at: @now)
    end

    # An edge is satisfiable when its prerequisite has done what the edge asks:
    # finished for a finish edge, released for a release edge. If the advance
    # that should have recorded it was interrupted (a raised on_terminal, a
    # deadlock abort, an edge added after its prerequisite finished) the
    # dependent waits forever, so advance the prerequisite again. A finish edge
    # on a released-but-running step is correctly open and is left alone.
    def readvance_edges
      terminal = WorkflowStep.states.values_at(*WorkflowStep::TERMINAL_STATES)
      prerequisite_ids = WorkflowDependency.where(satisfied_at: nil).joins(:prerequisite_step)
        .where("(workflow_dependencies.kind = :release AND workflow_steps.released_at IS NOT NULL) OR " \
               "(workflow_dependencies.kind = :finish AND workflow_steps.state IN (:terminal))",
          release: WorkflowDependency.kinds[:release], finish: WorkflowDependency.kinds[:finish], terminal: terminal)
        .distinct.order(:prerequisite_step_id).limit(@batch).pluck(:prerequisite_step_id)
      each_row(:readvance_edges, WorkflowStep.where(id: prerequisite_ids).order(:id).to_a) do |step|
        Coordinator.advance(step)
        true
      end
    end

    # A leaf step whose advance was interrupted leaves no open edge for the
    # previous pass to find, and a run that never closes blocks its target (one
    # active run per workflow and target) for good.
    def close_finished_runs
      terminal = WorkflowStep.states.values_at(*WorkflowStep::TERMINAL_STATES)
      runs = WorkflowRun.running
        .where("EXISTS (SELECT 1 FROM workflow_steps s WHERE s.workflow_run_id = workflow_runs.id)")
        .where("NOT EXISTS (SELECT 1 FROM workflow_steps s WHERE s.workflow_run_id = workflow_runs.id AND s.state NOT IN (?))", terminal)
        .order(:id).limit(@batch).to_a
      each_row(:close_finished_runs, runs) { |run| Coordinator.close_if_finished(run) }
    end

    # Ready steps never dispatched, or dispatched longer ago than the window for
    # their dispatch count: min(BASE_WINDOW * 2**(count - 1), MAX_WINDOW). The
    # exponent is capped so the power cannot overflow.
    # Returns how many it handed to the dispatcher, which skips any that were
    # claimed in the meantime.
    def redispatch_ready_steps
      steps = WorkflowStep.ready.where(<<~SQL.squish, now: @now, base: BASE_WINDOW.to_i, max: MAX_WINDOW.to_i).order(:id).limit(@batch).to_a
        dispatched_at IS NULL OR
        dispatched_at < :now::timestamp - LEAST(:base * POWER(2, LEAST(GREATEST(dispatch_count - 1, 0), 20)), :max) * INTERVAL '1 second'
      SQL
      Dispatcher.dispatch(steps) if steps.any?
      steps.size
    end
  end
end
