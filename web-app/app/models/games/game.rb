# == Schema Information
#
# Table name: games_games
#
#  id             :bigint           not null, primary key
#  description    :text
#  game_type      :integer          default("main_game"), not null
#  release_year   :integer
#  slug           :string           not null
#  title          :string           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  parent_game_id :bigint
#  series_id      :bigint
#
# Indexes
#
#  index_games_games_on_game_type       (game_type)
#  index_games_games_on_parent_game_id  (parent_game_id)
#  index_games_games_on_release_year    (release_year)
#  index_games_games_on_series_id       (series_id)
#  index_games_games_on_slug            (slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (parent_game_id => games_games.id)
#  fk_rails_...  (series_id => games_series.id)
#
class Games::Game < ApplicationRecord
  include SearchIndexable

  extend FriendlyId

  friendly_id :title, use: [:slugged, :finders]

  # Enums
  # Note: IGDB uses different numeric values - mapping is in IGDB provider
  enum :game_type, {
    main_game: 0,
    remake: 1,
    remaster: 2,
    expansion: 3,
    dlc: 4,
    bundle: 5,
    standalone_expansion: 6,
    mod: 7,
    episode: 8,
    season: 9,
    expanded_game: 10,
    port: 11
  }

  # Associations
  belongs_to :series, class_name: "Games::Series", optional: true
  belongs_to :parent_game, class_name: "Games::Game", optional: true
  has_many :child_games, class_name: "Games::Game", foreign_key: :parent_game_id, dependent: :nullify

  # Companies (developers/publishers)
  has_many :game_companies, class_name: "Games::GameCompany", dependent: :destroy
  has_many :companies, through: :game_companies, class_name: "Games::Company"

  # Platforms
  has_many :game_platforms, class_name: "Games::GamePlatform", dependent: :destroy
  has_many :platforms, through: :game_platforms, class_name: "Games::Platform"

  # Polymorphic associations (matching Music::Song pattern)
  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy
  has_many :category_items, as: :item, dependent: :destroy, inverse_of: :item
  has_many :categories, through: :category_items, class_name: "Games::Category", inverse_of: :games
  has_many :list_items, as: :listable, dependent: :destroy
  has_many :lists, through: :list_items
  has_many :ranked_items, as: :item, dependent: :destroy

  # Validations
  validates :title, presence: true
  validates :game_type, presence: true
  validates :release_year,
    numericality: {only_integer: true, greater_than: 1950, less_than_or_equal_to: Date.current.year + 2},
    allow_nil: true
  validate :parent_game_not_self
  validate :parent_game_valid_for_type

  # Callbacks
  before_validation :normalize_title

  # Scopes - Type filtering
  scope :main_games, -> { where(game_type: :main_game) }
  scope :remakes, -> { where(game_type: :remake) }
  scope :remasters, -> { where(game_type: :remaster) }
  scope :expansions, -> { where(game_type: :expansion) }
  scope :standalone, -> { where(game_type: [:main_game, :remake, :remaster]) }

  # Scopes - Year filtering (matches Music::Song pattern)
  scope :released_in, ->(year) { where(release_year: year) }
  scope :released_before, ->(year) { where("release_year <= ?", year) }
  scope :released_after, ->(year) { where("release_year >= ?", year) }
  scope :released_in_range, ->(start_year, end_year) { where(release_year: start_year..end_year) }

  # Scopes - Company filtering
  scope :by_developer, ->(company_id) {
    joins(:game_companies).where(games_game_companies: {company_id: company_id, developer: true}).distinct
  }
  scope :by_publisher, ->(company_id) {
    joins(:game_companies).where(games_game_companies: {company_id: company_id, publisher: true}).distinct
  }

  # Scopes - Platform filtering
  scope :on_platform, ->(platform_id) {
    joins(:game_platforms).where(games_game_platforms: {platform_id: platform_id}).distinct
  }
  scope :on_platform_family, ->(family) {
    joins(:platforms).where(games_platforms: {platform_family: family}).distinct
  }

  # Scopes - Series
  scope :in_series, ->(series_id) { where(series_id: series_id) }

  # Scopes - Identifier lookup
  scope :with_identifier, ->(identifier_type, value) {
    joins(:identifiers).where(identifiers: {identifier_type: identifier_type, value: value})
  }
  scope :with_igdb_id, ->(igdb_id) {
    with_identifier("games_igdb_id", igdb_id.to_s)
  }

  # Helper methods - Companies
  def developers
    companies.merge(Games::GameCompany.developers)
  end

  def publishers
    companies.merge(Games::GameCompany.publishers)
  end

  # Helper methods - Relationships
  def related_games_in_series
    return Games::Game.none unless series_id
    series.games.where.not(id: id)
  end

  def original_game
    parent_game if remake? || remaster?
  end

  # Search Methods
  def as_indexed_json
    developer_companies = game_companies.select(&:developer?).map(&:company)
    {
      title: title,
      developer_names: developer_companies.map(&:name),
      developer_ids: developer_companies.map(&:id),
      platform_ids: platforms.map(&:id),
      category_ids: categories.select { |c| !c.deleted }.map(&:id)
    }
  end

  private

  def normalize_title
    self.title = Services::Text::QuoteNormalizer.call(title) if title.present?
  end

  def parent_game_not_self
    if parent_game_id.present? && parent_game_id == id
      errors.add(:parent_game, "cannot reference itself")
    end
  end

  def parent_game_valid_for_type
    if parent_game_id.present? && main_game?
      errors.add(:parent_game, "cannot be set for main games")
    end
  end
end
