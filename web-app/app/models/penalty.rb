# == Schema Information
#
# Table name: penalties
#
#  id           :bigint           not null, primary key
#  category     :integer
#  description  :text
#  dynamic_type :integer
#  name         :string           not null
#  type         :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint
#
# Indexes
#
#  index_penalties_on_category  (category)
#  index_penalties_on_type      (type)
#  index_penalties_on_user_id   (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class Penalty < ApplicationRecord
  # Associations
  belongs_to :user, optional: true
  has_many :penalty_applications, dependent: :destroy
  has_many :ranking_configurations, through: :penalty_applications
  has_many :list_penalties, dependent: :destroy, inverse_of: :penalty
  has_many :lists, through: :list_penalties, inverse_of: :penalties

  # Enums
  #
  # percentage_western is only implemented for books lists (Books::List#percentage_western).
  # ::List#percentage_western returns nil for every other media type, so applying this
  # dynamic_type to a music/movies/games penalty has no effect -- no error, no penalty.
  enum :dynamic_type, {
    number_of_voters: 0,
    percentage_western: 1,
    voter_names_unknown: 2,
    voter_count_unknown: 3,
    category_specific: 4,
    location_specific: 5,
    num_years_covered: 6,
    voter_count_estimated: 7,
    creator_specific: 8
  }, allow_nil: true

  # How this penalty is grouped on the public /rankings page. Nullable: an
  # uncategorized penalty renders under "Other" rather than vanishing.
  enum :category, {
    voter_expertise: 0,
    voter_participation: 1,
    list_time_scope: 2,
    list_subject_scope: 3,
    list_integrity: 4
  }, allow_nil: true

  # Section headings for the public page. These are reader-facing questions
  # rather than schema names -- "Who voted" lands where "voter_expertise" does
  # not. Ordered as the page renders them.
  CATEGORY_TITLES = {
    "voter_expertise" => "Who voted",
    "voter_participation" => "How many voted",
    "list_time_scope" => "How much time the list covers",
    "list_subject_scope" => "How narrow the list's subject is",
    "list_integrity" => "How the list was made"
  }.freeze

  def self.category_title(category)
    CATEGORY_TITLES.fetch(category.to_s, "Other")
  end

  # Validations
  validates :name, presence: true
  validates :type, presence: true

  # Scopes
  scope :dynamic, -> { where.not(dynamic_type: nil) }
  scope :static, -> { where(dynamic_type: nil) }
  scope :by_dynamic_type, ->(dynamic_type) { where(dynamic_type: dynamic_type) }
  scope :by_category, ->(category) { where(category: category) }

  # Public Methods
  def dynamic?
    dynamic_type.present?
  end

  def static?
    dynamic_type.nil?
  end

  # Consistent across all penalty types
  def global?
    user_id.nil?  # Global means available to all users (no specific user)
  end

  def user_specific?
    user_id.present?  # User-specific means tied to a particular user
  end
end
