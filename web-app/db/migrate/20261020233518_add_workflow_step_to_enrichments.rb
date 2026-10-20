class AddWorkflowStepToEnrichments < ActiveRecord::Migration[8.1]
  def change
    add_reference :enrichments, :workflow_step, foreign_key: {on_delete: :nullify}
  end
end
