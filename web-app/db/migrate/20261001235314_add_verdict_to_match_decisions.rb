class AddVerdictToMatchDecisions < ActiveRecord::Migration[8.1]
  def change
    add_column :match_decisions, :verdict, :integer
  end
end
