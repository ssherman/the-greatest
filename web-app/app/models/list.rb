# == Schema Information
#
# Table name: lists
#
#  id                    :bigint           not null, primary key
#  category_specific     :boolean
#  description           :text
#  estimated_quality     :integer          default(0), not null
#  formatted_text        :text
#  high_quality_source   :boolean
#  items_json            :jsonb
#  location_specific     :boolean
#  name                  :string           not null
#  num_years_covered     :integer
#  number_of_voters      :integer
#  raw_html              :text
#  simplified_html       :text
#  source                :string
#  status                :integer          default("unapproved"), not null
#  type                  :string           not null
#  url                   :string
#  voter_count_estimated :boolean
#  voter_count_unknown   :boolean
#  voter_names_unknown   :boolean
#  year_published        :integer
#  yearly_award          :boolean
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  musicbrainz_series_id :string
#  submitted_by_id       :bigint
#
# Indexes
#
#  index_lists_on_submitted_by_id  (submitted_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (submitted_by_id => users.id)
#
class List < ApplicationRecord
  # Associations
  has_many :list_items, dependent: :destroy
  belongs_to :submitted_by, class_name: "User", optional: true
  has_many :list_penalties, dependent: :destroy, inverse_of: :list
  has_many :penalties, through: :list_penalties, inverse_of: :lists
  has_many :ai_chats, as: :parent, dependent: :destroy

  # Enums
  enum :status, {unapproved: 0, approved: 1, rejected: 2, active: 3}

  # Callbacks
  before_validation :parse_items_json_if_string
  before_save :auto_simplify_html, if: :should_simplify_html?

  # Validations
  validates :name, presence: true
  validates :type, presence: true
  validates :status, presence: true
  validates :url, format: {with: URI::RFC2396_PARSER.make_regexp, allow_blank: true}
  validates :num_years_covered, numericality: {greater_than: 0, only_integer: true}, allow_nil: true
  validate :items_json_format

  # Scopes
  scope :approved, -> { where(status: :approved) }
  scope :high_quality, -> { where(high_quality_source: true) }
  scope :by_year, ->(year) { where(year_published: year) }
  scope :yearly_awards, -> { where(yearly_award: true) }

  # Public Methods
  def has_penalties?
    penalties.any?
  end

  def global_penalties
    penalties.global
  end

  def user_penalties
    penalties.user_specific
  end

  def parse_with_ai!
    Services::Lists::ImportService.call(self)
  end

  def self.median_list_count(type: nil)
    # Get lists of the specified type, or all lists if no type specified
    scope = type ? where(type: type) : all

    # Get list item counts for lists that have items
    counts = scope.joins(:list_items)
      .group("lists.id")
      .count("list_items.id")
      .values
      .sort

    return 0 if counts.empty?

    # Calculate median
    len = counts.length
    if len.odd?
      counts[len / 2]
    else
      (counts[len / 2 - 1] + counts[len / 2]) / 2.0
    end
  end

  private

  def should_simplify_html?
    raw_html.present? && (new_record? || raw_html_changed?)
  end

  def auto_simplify_html
    self.simplified_html = Services::Html::SimplifierService.call(raw_html)
  end

  def parse_items_json_if_string
    return unless items_json.is_a?(String) && items_json.present?

    begin
      self.items_json = JSON.parse(items_json)
    rescue JSON::ParserError
      # Let the validation catch this
    end
  end

  def items_json_format
    return if items_json.blank?
    return if items_json.is_a?(Hash) || items_json.is_a?(Array)

    # If it's a string, try to parse it
    if items_json.is_a?(String)
      JSON.parse(items_json)
    end
  rescue JSON::ParserError => e
    errors.add(:items_json, "must be valid JSON: #{e.message}")
  end
end
