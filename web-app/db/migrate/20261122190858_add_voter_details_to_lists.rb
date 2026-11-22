class AddVoterDetailsToLists < ActiveRecord::Migration[8.1]
  def change
    add_column :lists, :voter_details, :text
  end
end
