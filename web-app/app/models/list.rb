# == Schema Information
#
# Table name: lists
#
#  id                  :bigint           not null, primary key
#  category_specific   :boolean
#  description         :text
#  estimated_quality   :integer          default(0), not null
#  formatted_text      :text
#  high_quality_source :boolean
#  items_json          :jsonb
#  location_specific   :boolean
#  name                :string           not null
#  number_of_voters    :integer
#  raw_html            :text
#  simplified_html     :text
#  source              :string
#  status              :integer          default("unapproved"), not null
#  type                :string           not null
#  url                 :string
#  voter_count_unknown :boolean
#  voter_names_unknown :boolean
#  year_published      :integer
#  yearly_award        :boolean
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  submitted_by_id     :bigint
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
  enum :status, {unapproved: 0, approved: 1, rejected: 2}

  # Callbacks
  before_save :auto_simplify_html, if: :should_simplify_html?

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

  private

  def should_simplify_html?
    raw_html.present? && (new_record? || raw_html_changed?)
  end

  def auto_simplify_html
    self.simplified_html = Services::Html::SimplifierService.call(raw_html)
  end
end
