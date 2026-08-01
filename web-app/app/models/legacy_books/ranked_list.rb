# == Schema Information
#
# Table name: ranked_lists
#
#  id                       :bigint           not null, primary key
#  weight                   :integer
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  list_id                  :bigint           not null
#  ranking_configuration_id :bigint           not null
#
# Indexes
#
#  index_ranked_lists_on_list_id_and_ranking_configuration_id  (list_id,ranking_configuration_id) UNIQUE
#  index_ranked_lists_on_ranking_configuration_id              (ranking_configuration_id)
#
# Foreign Keys
#
#  fk_rails_...  (list_id => lists.id)
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id)
#
module LegacyBooks
  class RankedList < Record
    self.table_name = "ranked_lists"
  end
end
