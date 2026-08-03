class DefaultUserListsToGridView < ActiveRecord::Migration[8.1]
  # The backfill is one-way on purpose. Legacy NULL (the old site's "user never
  # picked one") was mapped onto view_mode 0, so every row still sitting at 0 is
  # an unset preference rather than a choice. Once they move to 2 there is no way
  # to tell them apart from the 259 lists that genuinely chose grid, so `down`
  # restores the column default only.
  def up
    change_column_default :user_lists, :view_mode, from: 0, to: 2
    execute "UPDATE user_lists SET view_mode = 2 WHERE view_mode = 0"
  end

  def down
    change_column_default :user_lists, :view_mode, from: 2, to: 0
  end
end
