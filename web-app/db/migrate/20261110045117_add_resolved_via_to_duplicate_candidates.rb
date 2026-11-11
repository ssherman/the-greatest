class AddResolvedViaToDuplicateCandidates < ActiveRecord::Migration[8.1]
  def change
    add_column :duplicate_candidates, :resolved_via, :integer
  end
end
