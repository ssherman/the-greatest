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
    when "Music::RankingConfiguration"
      # Music can have both albums and songs
      unless item.is_a?(Music::Album) || item.is_a?(Music::Song)
        errors.add(:item, "must be a Music::Album or Music::Song")
      end
    end
  end
end
