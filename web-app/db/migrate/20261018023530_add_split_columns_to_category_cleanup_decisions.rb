class AddSplitColumnsToCategoryCleanupDecisions < ActiveRecord::Migration[8.1]
  def change
    add_column :category_cleanup_decisions, :extra_target_ids, :bigint, array: true, default: [], null: false
    add_column :category_cleanup_decisions, :split_assignments, :jsonb, default: {}, null: false
  end
end
