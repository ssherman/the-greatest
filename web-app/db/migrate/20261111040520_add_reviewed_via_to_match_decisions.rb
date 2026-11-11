class AddReviewedViaToMatchDecisions < ActiveRecord::Migration[8.1]
  def change
    add_column :match_decisions, :reviewed_via, :integer
  end
end
