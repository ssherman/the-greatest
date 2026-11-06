class TuneWorkflowIndexes < ActiveRecord::Migration[8.1]
  def change
    # Recovery#readvance_edges looks for unsatisfied edges every minute; almost
    # every edge is satisfied, so a partial index stays tiny.
    add_index :workflow_dependencies, :prerequisite_step_id,
      where: "satisfied_at IS NULL",
      name: "index_workflow_dependencies_open_on_prerequisite_step_id"

    # Both are the leading column of a unique composite index that already exists.
    remove_index :workflow_dependencies, :step_id, name: "index_workflow_dependencies_on_step_id"
    remove_index :workflow_steps, :workflow_run_id, name: "index_workflow_steps_on_workflow_run_id"

    # Rails named the edge's unique index after a hash of its columns.
    rename_index :workflow_dependencies, "idx_on_step_id_prerequisite_step_id_a38419b889",
      "index_workflow_dependencies_on_step_and_prerequisite"
  end
end
