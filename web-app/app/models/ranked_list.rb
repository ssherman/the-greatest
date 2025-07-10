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
    when "Music::RankingConfiguration"
      errors.add(:list, "must be a Music::List") unless list.is_a?(Music::List)
    end
  end
end
