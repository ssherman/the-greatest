class Current < ActiveSupport::CurrentAttributes
  attribute :domain
  # Set by WorkflowStepJob while a step runs, so ledger rows link to their step.
  attribute :workflow_step_id
  # Set by the admin controllers (web and API) so a merger's RecordMerge hook can
  # record who resolved a duplicate pair, and through which surface
  # ("admin_ui" or "api"). Both nil outside an admin request.
  attribute :acting_user, :acting_via
end
