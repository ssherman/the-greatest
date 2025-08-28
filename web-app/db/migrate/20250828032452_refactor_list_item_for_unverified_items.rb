class RefactorListItemForUnverifiedItems < ActiveRecord::Migration[8.0]
  def change
    # Make listable_type and listable_id nullable to support unverified items
    change_column_null :list_items, :listable_type, true
    change_column_null :list_items, :listable_id, true

    # Add metadata JSONB field to store item information before verification
    add_column :list_items, :metadata, :jsonb, default: {}

    # Add verified boolean field that defaults to false
    add_column :list_items, :verified, :boolean, default: false, null: false
  end
end
