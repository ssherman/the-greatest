class AddUserOwnershipToRankingConfigurations < ActiveRecord::Migration[8.1]
  def change
    add_column :ranking_configurations, :user_shared, :boolean, null: false, default: false
    add_column :ranking_configurations, :refresh_status, :integer, null: false, default: 0
    add_column :ranking_configurations, :needs_refresh, :boolean, null: false, default: false
    add_column :ranking_configurations, :refresh_requested_at, :datetime
    add_column :ranking_configurations, :last_refreshed_at, :datetime
    add_column :ranking_configurations, :last_refresh_error, :text
  end
end
