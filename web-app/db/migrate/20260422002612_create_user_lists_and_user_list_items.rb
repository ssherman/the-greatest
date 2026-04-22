class CreateUserListsAndUserListItems < ActiveRecord::Migration[8.1]
  def change
    create_table :user_lists do |t|
      t.references :user, null: false, foreign_key: true
      t.string :type, null: false
      t.string :name, null: false
      t.text :description
      t.integer :list_type, null: false
      t.integer :view_mode
      t.boolean :public, null: false, default: false
      t.integer :position

      t.timestamps
    end

    add_index :user_lists, [:user_id, :type]
    add_index :user_lists, :public, where: "public = true"

    create_table :user_list_items do |t|
      t.references :user_list, null: false, foreign_key: true
      t.references :listable, polymorphic: true, null: false
      t.integer :position, null: false
      t.date :completed_on

      t.timestamps
    end

    add_index :user_list_items, [:user_list_id, :listable_type, :listable_id],
      unique: true, name: "index_user_list_items_on_list_and_listable_unique"
    add_index :user_list_items, [:user_list_id, :position]
    add_index :user_list_items, [:user_list_id, :completed_on]
  end
end
