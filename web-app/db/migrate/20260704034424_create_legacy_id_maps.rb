class CreateLegacyIdMaps < ActiveRecord::Migration[8.1]
  def change
    create_table :legacy_id_maps do |t|
      t.string :model, null: false
      t.bigint :legacy_id, null: false
      t.bigint :new_id, null: false
      t.timestamps
    end
    add_index :legacy_id_maps, [:model, :legacy_id], unique: true
  end
end
