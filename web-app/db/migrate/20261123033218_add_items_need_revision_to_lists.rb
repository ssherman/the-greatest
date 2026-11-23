class AddItemsNeedRevisionToLists < ActiveRecord::Migration[8.1]
  def change
    add_column :lists, :items_need_revision, :boolean, default: false, null: false
  end
end
