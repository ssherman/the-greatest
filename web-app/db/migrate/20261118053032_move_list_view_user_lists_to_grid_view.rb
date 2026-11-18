class MoveListViewUserListsToGridView < ActiveRecord::Migration[8.1]
  # The List view mode (integer 0) is retired. Lists still on it move to grid,
  # the default. One-way: there is no telling afterwards which lists were on 0.
  def up
    execute "UPDATE user_lists SET view_mode = 2 WHERE view_mode = 0"
  end

  def down
  end
end
