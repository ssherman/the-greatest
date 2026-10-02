class AddAccountKindToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :account_kind, :integer, null: false, default: 0
  end
end
