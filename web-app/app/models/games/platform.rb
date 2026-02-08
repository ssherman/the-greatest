# == Schema Information
#
# Table name: games_platforms
#
#  id              :bigint           not null, primary key
#  abbreviation    :string
#  name            :string           not null
#  platform_family :integer
#  slug            :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_games_platforms_on_platform_family  (platform_family)
#  index_games_platforms_on_slug             (slug) UNIQUE
#
class Games::Platform < ApplicationRecord
  extend FriendlyId

  friendly_id :name, use: [:slugged, :finders]

  # Enums
  enum :platform_family, {
    playstation: 0,
    xbox: 1,
    nintendo: 2,
    pc: 3,
    mobile: 4,
    other: 5
  }

  # Associations
  has_many :game_platforms, class_name: "Games::GamePlatform", dependent: :destroy
  has_many :games, through: :game_platforms, class_name: "Games::Game"

  # Validations
  validates :name, presence: true

  # Scopes
  scope :by_family, ->(family) { where(platform_family: family) }
end
