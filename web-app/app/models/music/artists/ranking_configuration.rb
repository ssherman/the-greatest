# == Schema Information
#
# Table name: ranking_configurations
#
#  id                                :bigint           not null, primary key
#  algorithm_version                 :integer          default(1), not null
#  apply_list_dates_penalty          :boolean          default(TRUE), not null
#  archived                          :boolean          default(FALSE), not null
#  bonus_pool_percentage             :decimal(10, 2)   default(3.0), not null
#  description                       :text
#  exponent                          :decimal(10, 2)   default(3.0), not null
#  global                            :boolean          default(TRUE), not null
#  inherit_penalties                 :boolean          default(TRUE), not null
#  list_limit                        :integer
#  max_list_dates_penalty_age        :integer          default(50)
#  max_list_dates_penalty_percentage :integer          default(80)
#  min_list_weight                   :integer          default(1), not null
#  name                              :string           not null
#  primary                           :boolean          default(FALSE), not null
#  primary_mapped_list_cutoff_limit  :integer
#  published_at                      :datetime
#  type                              :string           not null
#  created_at                        :datetime         not null
#  updated_at                        :datetime         not null
#  inherited_from_id                 :bigint
#  primary_mapped_list_id            :bigint
#  secondary_mapped_list_id          :bigint
#  user_id                           :bigint
#
# Indexes
#
#  index_ranking_configurations_on_inherited_from_id         (inherited_from_id)
#  index_ranking_configurations_on_primary_mapped_list_id    (primary_mapped_list_id)
#  index_ranking_configurations_on_secondary_mapped_list_id  (secondary_mapped_list_id)
#  index_ranking_configurations_on_type_and_global           (type,global)
#  index_ranking_configurations_on_type_and_primary          (type,primary)
#  index_ranking_configurations_on_type_and_user_id          (type,user_id)
#  index_ranking_configurations_on_user_id                   (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (inherited_from_id => ranking_configurations.id)
#  fk_rails_...  (primary_mapped_list_id => lists.id)
#  fk_rails_...  (secondary_mapped_list_id => lists.id)
#  fk_rails_...  (user_id => users.id)
#
module Music
  module Artists
    class RankingConfiguration < ::RankingConfiguration
    end
  end
end
