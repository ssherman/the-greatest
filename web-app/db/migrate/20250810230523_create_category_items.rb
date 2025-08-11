class CreateCategoryItems < ActiveRecord::Migration[8.0]
  def change
    create_table :category_items do |t|
      t.references :category, null: false, foreign_key: true
      t.references :item, polymorphic: true, null: false

      t.timestamps
    end

    add_index :category_items, [:category_id, :item_type, :item_id], unique: true
    add_index :category_items, [:item_type, :item_id]
  end
end
