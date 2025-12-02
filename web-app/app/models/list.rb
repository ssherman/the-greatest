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
#  wizard_state          :jsonb
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

  # Wizard step names for mapping current_step index to step name
  WIZARD_STEPS = %w[source parse enrich validate review import complete].freeze

  def wizard_current_step
    safe_wizard_state.fetch("current_step", 0)
  end

  def current_step_name
    WIZARD_STEPS[wizard_current_step] || "source"
  end

  # ============================================
  # Step-Namespaced Status Methods (NEW)
  # ============================================

  def wizard_step_status(step_name)
    wizard_step_data(step_name).fetch("status", "idle")
  end

  def wizard_step_progress(step_name)
    wizard_step_data(step_name).fetch("progress", 0)
  end

  def wizard_step_error(step_name)
    wizard_step_data(step_name).fetch("error", nil)
  end

  def wizard_step_metadata(step_name)
    wizard_step_data(step_name).fetch("metadata", {})
  end

  def update_wizard_step_status(step:, status:, progress: nil, error: nil, metadata: {})
    step_key = step.to_s
    current_step_state = wizard_step_data(step_key)

    new_step_state = {
      "status" => status,
      "progress" => progress || current_step_state.fetch("progress", 0),
      "error" => error,
      "metadata" => current_step_state.fetch("metadata", {}).merge(metadata)
    }

    steps_data = wizard_steps_data.merge(step_key => new_step_state)
    new_state = safe_wizard_state.merge("steps" => steps_data)

    update!(wizard_state: new_state)
  end

  def reset_wizard_step!(step_name)
    step_key = step_name.to_s
    steps_data = wizard_steps_data.merge(step_key => default_step_state)
    new_state = safe_wizard_state.merge("steps" => steps_data)

    update!(wizard_state: new_state)
  end

  # ============================================
  # Legacy Methods (Deprecated - delegate to current step)
  # ============================================

  def wizard_job_status
    wizard_step_status(current_step_name)
  end

  def wizard_job_progress
    wizard_step_progress(current_step_name)
  end

  def wizard_job_error
    wizard_step_error(current_step_name)
  end

  def wizard_job_metadata
    wizard_step_metadata(current_step_name)
  end

  def wizard_in_progress?
    safe_wizard_state.fetch("started_at", nil).present? &&
      safe_wizard_state.fetch("completed_at", nil).nil?
  end

  def update_wizard_job_status(status:, progress: nil, error: nil, metadata: {})
    update_wizard_step_status(
      step: current_step_name,
      status: status,
      progress: progress,
      error: error,
      metadata: metadata
    )
  end

  def reset_wizard!
    update!(wizard_state: {
      "current_step" => 0,
      "started_at" => Time.current.iso8601,
      "completed_at" => nil,
      "steps" => {}
    })
  end

  private

  def safe_wizard_state
    wizard_state || {}
  end

  def wizard_steps_data
    safe_wizard_state.fetch("steps", {})
  end

  def wizard_step_data(step_name)
    wizard_steps_data.fetch(step_name.to_s, default_step_state)
  end

  def default_step_state
    {"status" => "idle", "progress" => 0, "error" => nil, "metadata" => {}}
  end

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
