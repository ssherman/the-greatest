# == Schema Information
#
# Table name: ranked_items
#
#  id                       :bigint           not null, primary key
#  item_type                :string           not null
#  rank                     :integer
#  score                    :decimal(10, 2)
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  item_id                  :bigint           not null
#  ranking_configuration_id :bigint           not null
#
# Indexes
#
#  index_ranked_items_on_config_and_rank                 (ranking_configuration_id,rank)
#  index_ranked_items_on_config_and_score                (ranking_configuration_id,score)
#  index_ranked_items_on_item                            (item_type,item_id)
#  index_ranked_items_on_item_and_ranking_config_unique  (item_id,item_type,ranking_configuration_id) UNIQUE
#  index_ranked_items_on_ranking_configuration_id        (ranking_configuration_id)
#
# Foreign Keys
#
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id)
#
class RankedItem < ApplicationRecord
  belongs_to :item, polymorphic: true
  belongs_to :ranking_configuration

  # Uniqueness validation
  validates :item_id, uniqueness: {scope: [:item_type, :ranking_configuration_id], message: "can only be ranked once per ranking configuration"}

  # Custom validation for type matching
  validate :item_type_matches_ranking_configuration

  # Only keep necessary scopes
  scope :by_rank, -> { order(:rank) }
  scope :by_score, -> { where.not(score: nil).order(score: :desc) }

  private

  def item_type_matches_ranking_configuration
    return unless item && ranking_configuration

    # Check that the item type matches the ranking configuration type
    case ranking_configuration.type
    when "Books::RankingConfiguration"
      errors.add(:item, "must be a Books::Book") unless item.is_a?(Books::Book)
    when "Movies::RankingConfiguration"
      errors.add(:item, "must be a Movies::Movie") unless item.is_a?(Movies::Movie)
    when "Games::RankingConfiguration"
      errors.add(:item, "must be a Games::Game") unless item.is_a?(Games::Game)
    when "Music::Albums::RankingConfiguration"
      errors.add(:item, "must be a Music::Album") unless item.is_a?(Music::Album)
    when "Music::Songs::RankingConfiguration"
      errors.add(:item, "must be a Music::Song") unless item.is_a?(Music::Song)
    end
  end
end
