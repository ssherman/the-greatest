class SetUserListsViewModeDefault < ActiveRecord::Migration[8.1]
  def change
    change_column_default :user_lists, :view_mode, from: nil, to: 0
    reversible do |dir|
      dir.up do
        execute "UPDATE user_lists SET view_mode = 0 WHERE view_mode IS NULL"
      end
    end
    change_column_null :user_lists, :view_mode, false
  end
end
