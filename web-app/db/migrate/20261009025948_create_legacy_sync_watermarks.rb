class CreateLegacySyncWatermarks < ActiveRecord::Migration[8.1]
  def change
    create_table :legacy_sync_watermarks do |t|
      t.string :key, null: false
      t.bigint :value, null: false
      t.timestamps
    end
    add_index :legacy_sync_watermarks, :key, unique: true
  end
end
