class CreateWorkflowDependencies < ActiveRecord::Migration[8.1]
  def change
    create_table :workflow_dependencies do |t|
      t.references :step, null: false, foreign_key: {to_table: :workflow_steps, on_delete: :cascade}
      t.references :prerequisite_step, null: false, foreign_key: {to_table: :workflow_steps, on_delete: :cascade}
      t.integer :kind, null: false, default: 0
      t.datetime :satisfied_at

      t.timestamps
    end

    add_index :workflow_dependencies, [:step_id, :prerequisite_step_id], unique: true
  end
end
