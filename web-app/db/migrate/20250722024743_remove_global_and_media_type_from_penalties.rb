class RemoveGlobalAndMediaTypeFromPenalties < ActiveRecord::Migration[8.0]
  def change
    remove_index :penalties, :global
    remove_index :penalties, :media_type
    remove_column :penalties, :global, :boolean, default: false, null: false
    remove_column :penalties, :media_type, :integer, default: 0, null: false
  end
end
