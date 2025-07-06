class AddSubmittedByToLists < ActiveRecord::Migration[8.0]
  def change
    add_reference :lists, :submitted_by, null: true, foreign_key: {to_table: :users}
  end
end
