class CreateWorkflowRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :workflow_runs do |t|
      t.string :workflow, null: false
      t.integer :definition_version, null: false
      t.references :enrichable, polymorphic: true, null: false
      t.integer :status, null: false, default: 0
      t.jsonb :options, null: false, default: {}
      t.string :initiated_by, null: false
      t.references :parent_run, foreign_key: {to_table: :workflow_runs, on_delete: :nullify}
      t.datetime :started_at
      t.datetime :finished_at
      t.text :error_summary

      t.timestamps
    end

    add_index :workflow_runs, [:workflow, :enrichable_type, :enrichable_id],
      unique: true, where: "status = 0", name: "index_workflow_runs_one_active"
    add_index :workflow_runs, :status
  end
end
