class CreateClearedFields < ActiveRecord::Migration[8.1]
  def change
    create_table :cleared_fields do |t|
      t.references :clearable, polymorphic: true, null: false, index: false
      t.string :field_name, null: false
      t.references :cleared_by, null: true, foreign_key: {to_table: :users, on_delete: :nullify}
      t.integer :cleared_via, null: false

      t.timestamps
    end

    add_index :cleared_fields, [:clearable_type, :clearable_id, :field_name], unique: true,
      name: "index_cleared_fields_on_clearable_and_field_name"
  end
end
