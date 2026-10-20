class Current < ActiveSupport::CurrentAttributes
  attribute :domain
  # Set by WorkflowStepJob while a step runs, so ledger rows link to their step.
  attribute :workflow_step_id
end
