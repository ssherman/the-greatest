class CreateCorrectionFields < ActiveRecord::Migration[8.1]
  def change
    create_table :correction_fields do |t|
      t.references :correction, null: false, foreign_key: true
      t.string :field_name, null: false
      t.jsonb :old_value
      t.jsonb :new_value
      t.integer :status, null: false, default: 0
      t.datetime :applied_at

      t.timestamps
    end

    # One proposal per field per correction. The submission service already
    # dedupes, but a unique index is what makes that true rather than hoped.
    add_index :correction_fields, [:correction_id, :field_name], unique: true
  end
end
