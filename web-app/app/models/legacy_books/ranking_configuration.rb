# == Schema Information
#
# Table name: ranking_configurations
#
#  id                               :bigint           not null, primary key
#  algorithm_version                :integer          default(1), not null
#  apply_global_age_penalty         :boolean          default(FALSE), not null
#  apply_list_dates_penalty         :boolean          default(FALSE), not null
#  archived                         :boolean          default(FALSE), not null
#  bonus_pool_percentage            :decimal(10, 2)   default(2.0), not null
#  description                      :text
#  exponent                         :decimal(10, 2)   default(1.5), not null
#  global                           :boolean          default(TRUE), not null
#  inherit_list_cons                :boolean          default(TRUE), not null
#  list_cons_are_percentages        :boolean          default(FALSE), not null
#  list_limit                       :integer
#  max_age_for_penalty              :integer
#  max_penalty_percentage           :integer
#  min_list_weight                  :integer          default(-50), not null
#  min_max_normalization            :boolean          default(FALSE), not null
#  name                             :string           not null
#  primary                          :boolean          default(FALSE), not null
#  primary_mapped_list_cutoff_limit :integer
#  published_at                     :datetime
#  starting_score                   :integer          default(150), not null
#  created_at                       :datetime         not null
#  updated_at                       :datetime         not null
#  inherited_from_id                :integer
#  primary_mapped_list_id           :bigint
#  secondary_mapped_list_id         :bigint
#  user_id                          :bigint
#
# Indexes
#
#  index_ranking_configurations_on_primary_mapped_list_id    (primary_mapped_list_id)
#  index_ranking_configurations_on_secondary_mapped_list_id  (secondary_mapped_list_id)
#  index_ranking_configurations_on_user_id                   (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (primary_mapped_list_id => lists.id)
#  fk_rails_...  (secondary_mapped_list_id => lists.id)
#  fk_rails_...  (user_id => users.id)
#
module LegacyBooks
  class RankingConfiguration < Record
    self.table_name = "ranking_configurations"
  end
end
