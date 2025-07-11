class CreatePenaltyApplications < ActiveRecord::Migration[8.0]
  def change
    create_table :penalty_applications do |t|
      t.references :penalty, null: false, foreign_key: true
      t.references :ranking_configuration, null: false, foreign_key: true
      t.integer :value, default: 0, null: false

      t.timestamps
    end

    add_index :penalty_applications, [:penalty_id, :ranking_configuration_id], unique: true, name: "index_penalty_applications_on_penalty_and_config"
  end
end
