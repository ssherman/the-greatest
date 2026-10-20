class CreateWorkflowSteps < ActiveRecord::Migration[8.1]
  def change
    create_table :workflow_steps do |t|
      t.references :workflow_run, null: false, foreign_key: true
      t.string :key, null: false
      t.integer :state, null: false, default: 0
      t.string :outcome
      t.datetime :released_at
      t.datetime :run_after
      t.integer :attempts, null: false, default: 0
      t.integer :max_attempts, null: false, default: 3
      t.string :lease_token
      t.integer :lease_seconds, null: false
      t.datetime :lease_expires_at
      t.datetime :dispatched_at
      t.integer :dispatch_count, null: false, default: 0
      t.string :queue, null: false
      t.jsonb :result, null: false, default: {}
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :workflow_steps, [:workflow_run_id, :key], unique: true
    add_index :workflow_steps, [:state, :run_after]
    add_index :workflow_steps, [:state, :dispatched_at]
    add_index :workflow_steps, [:state, :lease_expires_at]
  end
end
