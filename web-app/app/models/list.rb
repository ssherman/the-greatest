class List < ApplicationRecord
  # Associations
  has_many :list_items, dependent: :destroy
  belongs_to :submitted_by, class_name: "User", optional: true

  # Enums
  enum :status, {unapproved: 0, approved: 1, rejected: 2}

  # Validations
  validates :name, presence: true
  validates :type, presence: true
  validates :status, presence: true
  validates :url, format: {with: URI::RFC2396_PARSER.make_regexp, allow_blank: true}

  # Scopes
  scope :approved, -> { where(status: :approved) }
  scope :high_quality, -> { where(high_quality_source: true) }
  scope :by_year, ->(year) { where(year_published: year) }
  scope :yearly_awards, -> { where(yearly_award: true) }
end
