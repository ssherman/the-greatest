class AddActivatedAtToLists < ActiveRecord::Migration[8.1]
  def up
    add_column :lists, :activated_at, :datetime
    add_index :lists, :activated_at

    # status 3 is the `active` enum value. No historical activation date exists in
    # either database, so updated_at is the best available approximation for rows
    # that predate this column.
    execute "UPDATE lists SET activated_at = updated_at WHERE status = 3"
  end

  def down
    remove_column :lists, :activated_at
  end
end
