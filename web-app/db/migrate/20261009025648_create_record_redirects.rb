class CreateRecordRedirects < ActiveRecord::Migration[8.1]
  def change
    create_table :record_redirects do |t|
      t.string :item_type, null: false
      t.bigint :from_id, null: false
      t.bigint :to_id
      t.timestamps
    end
    add_index :record_redirects, [:item_type, :from_id], unique: true
  end
end
