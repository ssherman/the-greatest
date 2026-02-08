# == Schema Information
#
# Table name: games_series
#
#  id          :bigint           not null, primary key
#  description :text
#  name        :string           not null
#  slug        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_games_series_on_name  (name)
#  index_games_series_on_slug  (slug) UNIQUE
#
class Games::Series < ApplicationRecord
  extend FriendlyId

  friendly_id :name, use: [:slugged, :finders]

  # Associations
  has_many :games, class_name: "Games::Game", dependent: :nullify

  # Validations
  validates :name, presence: true

  # Callbacks
  before_validation :normalize_name

  private

  def normalize_name
    self.name = Services::Text::QuoteNormalizer.call(name) if name.present?
  end
end
