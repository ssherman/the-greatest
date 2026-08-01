# == Schema Information
#
# Table name: list_cons
#
#  id                       :bigint           not null, primary key
#  description              :text
#  dynamic                  :boolean          default(FALSE), not null
#  dynamic_type             :integer
#  name                     :string           not null
#  points                   :integer          not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  ranking_configuration_id :bigint           not null
#
# Indexes
#
#  index_list_cons_on_ranking_configuration_id  (ranking_configuration_id)
#
# Foreign Keys
#
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id)
#
module LegacyBooks
  class ListCon < Record
    self.table_name = "list_cons"
  end
end
