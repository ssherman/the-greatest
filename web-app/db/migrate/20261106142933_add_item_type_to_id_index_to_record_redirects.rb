class AddItemTypeToIdIndexToRecordRedirects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Apply::Leftovers walks record_redirects backwards (which books were redirected into this one) on every sweep.
  def change
    add_index :record_redirects, [:item_type, :to_id], algorithm: :concurrently, if_not_exists: true
  end
end
