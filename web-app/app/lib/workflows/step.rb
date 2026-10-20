# One declared step of a workflow definition. The coordinator copies the
# scalar fields onto a WorkflowStep row when it plans a run; the callables stay
# here and are looked up through the definition at execution time.
#
# waits_on maps a prerequisite step key to :finish (wait for it to reach a
# terminal state) or :release (proceed as soon as it hands off).
# skip_if is evaluated by the coordinator at advance time, so a step that will
# be skipped is never dispatched into a long queue just to say so.
module Workflows
  Step = Data.define(:key, :queue, :waits_on, :max_attempts, :lease, :adapter, :skip_if, :on_terminal) do
    def self.build(key:, queue:, adapter:, waits_on: {}, max_attempts: 3, lease: 10.minutes, skip_if: nil, on_terminal: nil)
      new(key: key, queue: queue, waits_on: waits_on, max_attempts: max_attempts, lease: lease,
        adapter: adapter, skip_if: skip_if, on_terminal: on_terminal)
    end
  end
end
