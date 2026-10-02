class AddRerunRequestedToCsvExports < ActiveRecord::Migration[8.1]
  def change
    add_column :csv_exports, :rerun_requested, :boolean, null: false, default: false
  end
end
