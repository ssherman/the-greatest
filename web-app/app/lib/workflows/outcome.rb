# What a step adapter hands back to the coordinator. Failure is not an
# outcome: an adapter signals it by raising, so the coordinator's retry and
# backoff path is the only one that handles errors.
module Workflows
  Outcome = Data.define(:kind, :outcome, :result, :run_after, :release) do
    # The step did its work. `outcome` is a short label stored on the step.
    def self.succeeded(outcome, result = {})
      new(kind: :succeeded, outcome: outcome, result: result, run_after: nil, release: false)
    end

    # The step had nothing to do (nothing missing, no identifier to look up).
    def self.skipped(outcome)
      new(kind: :skipped, outcome: outcome, result: {}, run_after: nil, release: false)
    end

    # Come back at `until_time` without using an attempt (rate limit, queue
    # position). `release: true` lets dependents proceed while the step waits.
    # A nil time is refused: the sweep only wakes a step whose run_after has
    # passed, so the step would wait forever.
    def self.wait(until_time, release: false, result: {})
      raise ArgumentError, "Outcome.wait needs a time to wake at" if until_time.nil?

      new(kind: :wait, outcome: nil, result: result, run_after: until_time, release: release)
    end
  end
end
