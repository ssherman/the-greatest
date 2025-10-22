class AddCalculatedWeightDetailsToRankedLists < ActiveRecord::Migration[8.0]
  def change
    add_column :ranked_lists, :calculated_weight_details, :jsonb
  end
end
