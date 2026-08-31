class CreateExternalRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :external_records do |t|
      t.integer :source, null: false
      t.string :source_id, null: false
      t.jsonb :payload, null: false
      t.integer :schema_version, null: false, default: 1
      t.datetime :fetched_at, null: false

      t.timestamps
    end

    add_index :external_records, [:source, :source_id], unique: true
    add_index :external_records, [:source, :fetched_at]
  end
end
