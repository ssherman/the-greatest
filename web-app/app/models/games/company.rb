# == Schema Information
#
# Table name: games_companies
#
#  id           :bigint           not null, primary key
#  country      :string(2)
#  description  :text
#  name         :string           not null
#  slug         :string           not null
#  year_founded :integer
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_games_companies_on_name  (name)
#  index_games_companies_on_slug  (slug) UNIQUE
#
class Games::Company < ApplicationRecord
  extend FriendlyId

  friendly_id :name, use: [:slugged, :finders]

  # Associations
  has_many :game_companies, class_name: "Games::GameCompany", dependent: :destroy
  has_many :games, through: :game_companies, class_name: "Games::Game"

  # Polymorphic associations
  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy

  # Validations
  validates :name, presence: true
  validates :country, length: {is: 2}, allow_blank: true

  # Callbacks
  before_validation :normalize_name

  # Scopes
  scope :developers, -> {
    joins(:game_companies).where(games_game_companies: {developer: true}).distinct
  }
  scope :publishers, -> {
    joins(:game_companies).where(games_game_companies: {publisher: true}).distinct
  }

  # Helper methods
  def developed_games
    games.joins(:game_companies)
      .where(games_game_companies: {developer: true, company_id: id})
  end

  def published_games
    games.joins(:game_companies)
      .where(games_game_companies: {publisher: true, company_id: id})
  end

  private

  def normalize_name
    self.name = Services::Text::QuoteNormalizer.call(name) if name.present?
  end
end
