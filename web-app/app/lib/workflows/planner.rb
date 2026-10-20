# Writes a workflow run: the run row, one step row per definition step and one
# dependency row per edge, then settles every step whose prerequisites are
# already met. It plans inside the caller's transaction and never dispatches;
# the caller enqueues the returned ready steps after commit.
module Workflows
  class Planner
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    NOT_REQUESTED = "not_requested"

    # options: engine keys are "only" (step keys to run; the rest are planned
    # skipped) and "start_at" (a step key; the steps before it are planned
    # skipped). Anything else is kept on the run for adapters.
    # waits: {step_key => [WorkflowStep]} extra cross-run prerequisites, always
    # release edges. skips: {step_key => outcome} steps planned skipped.
    # start_after: steps that could start now wait until this time instead.
    def self.call(...)
      new(...).call
    end

    def initialize(definition:, enrichable:, initiated_by:, options: {}, waits: {}, skips: {},
      start_after: nil, parent_run: nil, supersede: false)
      @definition = definition
      @enrichable = enrichable
      @initiated_by = initiated_by
      @options = options.deep_stringify_keys
      @waits = waits.transform_keys(&:to_s)
      @skips = skips.transform_keys(&:to_s)
      @start_after = start_after
      @parent_run = parent_run
      @supersede = supersede
    end

    def call
      errors = validate
      return failure(errors) if errors.any?

      plan_in_transaction
    rescue ActiveRecord::RecordNotUnique
      # Another worker planned the same target between our check and our insert.
      existing = active_run
      raise unless existing

      success(run: existing, reused: true, ready_steps: [])
    end

    private

    def plan_in_transaction
      ActiveRecord::Base.transaction(requires_new: true) do
        existing = active_run
        if existing && !@supersede
          next success(run: existing, reused: true, ready_steps: [])
        end
        Workflows::Coordinator.cancel(existing, outcome: "superseded") if existing

        run = create_run
        steps = create_steps(run)
        create_dependencies(steps)
        settle(steps)
        success(run: run, reused: false, ready_steps: run.steps.where(state: :ready).order(:id).to_a)
      end
    end

    def active_run
      WorkflowRun.running.find_by(workflow: @definition.workflow, enrichable: @enrichable)
    end

    def create_run
      WorkflowRun.create!(workflow: @definition.workflow, definition_version: @definition.version,
        enrichable: @enrichable, initiated_by: @initiated_by, options: @options,
        parent_run: @parent_run, started_at: Time.current)
    end

    # Steps the plan skips outright are born terminal and released, so edges on
    # them are satisfied at once.
    def create_steps(run)
      now = Time.current
      @definition.steps.to_h do |declared|
        key = declared.key.to_s
        attributes = {key: key, queue: declared.queue.to_s, max_attempts: declared.max_attempts,
                      lease_seconds: declared.lease.to_i}
        if (outcome = planned_skip(key))
          attributes.merge!(state: :skipped, outcome: outcome, released_at: now, finished_at: now)
        end
        [key, run.steps.create!(attributes)]
      end
    end

    def create_dependencies(steps)
      @definition.steps.each do |declared|
        step = steps.fetch(declared.key.to_s)
        declared.waits_on.each do |prerequisite_key, kind|
          create_edge(step, steps.fetch(prerequisite_key.to_s), kind)
        end
        @waits.fetch(step.key, []).each { |prerequisite| create_edge(step, prerequisite.reload, :release) }
      end
    end

    def create_edge(step, prerequisite, kind)
      edge = WorkflowDependency.new(step: step, prerequisite_step: prerequisite, kind: kind)
      satisfied = edge.finish? ? prerequisite.terminal? : prerequisite.released?
      edge.satisfied_at = Time.current if satisfied
      edge.save!
    end

    # Evaluates the blocked steps in definition order, repeating while a pass
    # changed anything: a step skipped or released in one pass can satisfy an
    # edge of a step the pass already looked at. A work list, not recursion.
    def settle(steps)
      pending = steps.values.select(&:blocked?)
      loop do
        changed = pending.map { |step| Workflows::Coordinator.evaluate(step, run_after: @start_after) }
          .any? { |result| %i[ready waiting skipped released].include?(result) }
        pending.select!(&:blocked?)
        break unless changed
      end
    end

    def planned_skip(key)
      return NOT_REQUESTED if unrequested?(key)

      @skips[key]
    end

    def unrequested?(key)
      keys = @definition.steps.map { |declared| declared.key.to_s }
      return true if @options["only"] && !@options["only"].map(&:to_s).include?(key)

      start_at = @options["start_at"]
      !!start_at && keys.index(key) < keys.index(start_at.to_s)
    end

    def validate
      known = @definition.steps.map { |declared| declared.key.to_s }
      errors = []
      unless @enrichable.is_a?(@definition.target_class)
        errors << "#{@definition.workflow} runs on #{@definition.target_class}, not #{@enrichable.class}"
      end
      referenced = {"only" => Array(@options["only"]).map(&:to_s), "start_at" => Array(@options["start_at"]).map(&:to_s),
                    "skips" => @skips.keys, "waits" => @waits.keys}
      referenced.each do |source, keys|
        (keys - known).each { |key| errors << "#{source} names unknown step #{key.inspect}" }
      end
      errors
    end

    def success(data)
      Result.new(success?: true, data: data, errors: [])
    end

    def failure(errors)
      Result.new(success?: false, data: nil, errors: errors)
    end
  end
end
