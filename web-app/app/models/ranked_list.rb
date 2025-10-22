# == Schema Information
#
# Table name: ranked_lists
#
#  id                        :bigint           not null, primary key
#  calculated_weight_details :jsonb
#  weight                    :integer
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  list_id                   :bigint           not null
#  ranking_configuration_id  :bigint           not null
#
# Indexes
#
#  index_ranked_lists_on_list_id                   (list_id)
#  index_ranked_lists_on_ranking_configuration_id  (ranking_configuration_id)
#
# Foreign Keys
#
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id)
#
class RankedList < ApplicationRecord
  belongs_to :list
  belongs_to :ranking_configuration

  # Uniqueness validation
  validates :list_id, uniqueness: {scope: :ranking_configuration_id, message: "can only be added once per ranking configuration"}

  # Custom validation for type matching
  validate :list_type_matches_ranking_configuration

  private

  def list_type_matches_ranking_configuration
    return unless list && ranking_configuration

    # Check that the list type matches the ranking configuration type
    case ranking_configuration.type
    when "Books::RankingConfiguration"
      errors.add(:list, "must be a Books::List") unless list.is_a?(Books::List)
    when "Movies::RankingConfiguration"
      errors.add(:list, "must be a Movies::List") unless list.is_a?(Movies::List)
    when "Games::RankingConfiguration"
      errors.add(:list, "must be a Games::List") unless list.is_a?(Games::List)
    when "Music::Albums::RankingConfiguration"
      errors.add(:list, "must be a Music::Albums::List") unless list.is_a?(Music::Albums::List)
    when "Music::Songs::RankingConfiguration"
      errors.add(:list, "must be a Music::Songs::List") unless list.is_a?(Music::Songs::List)
    end
  end
end
