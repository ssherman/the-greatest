class CreateListItems < ActiveRecord::Migration[8.0]
  def change
    create_table :list_items do |t|
      t.references :list, null: false, foreign_key: true
      t.references :listable, polymorphic: true, null: false
      t.integer :position

      t.timestamps
    end

    add_index :list_items, [:list_id, :position]
    add_index :list_items, [:list_id, :listable_type, :listable_id], unique: true, name: "index_list_items_on_list_and_listable_unique"
  end
end
