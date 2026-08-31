class AddYearAndSecondaryCutoffToRankingConfigurations < ActiveRecord::Migration[8.1]
  def change
    # The year a configuration scopes to; NULL on an all-time configuration.
    # Until now the year existed only inside the name string, which neither the
    # generator (which stamps year_published on its output lists) nor the
    # clone action (which computes year + 1) can read reliably.
    add_column :ranking_configurations, :year, :integer

    # A COUNT, matching primary_mapped_list_cutoff_limit, which legacy applied as
    # limit(n) then offset(n). Read as offset(primary).limit(secondary).
    # NULL means uncapped.
    add_column :ranking_configurations, :secondary_mapped_list_cutoff_limit, :integer
  end
end
