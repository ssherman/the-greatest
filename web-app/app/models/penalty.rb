# == Schema Information
#
# Table name: penalties
#
#  id           :bigint           not null, primary key
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
#  index_penalties_on_type     (type)
#  index_penalties_on_user_id  (user_id)
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
  enum :dynamic_type, {
    number_of_voters: 0,
    percentage_western: 1,
    voter_names_unknown: 2,
    voter_count_unknown: 3,
    category_specific: 4,
    location_specific: 5,
    num_years_covered: 6
  }, allow_nil: true

  # Validations
  validates :name, presence: true
  validates :type, presence: true

  # Scopes
  scope :dynamic, -> { where.not(dynamic_type: nil) }
  scope :static, -> { where(dynamic_type: nil) }
  scope :by_dynamic_type, ->(dynamic_type) { where(dynamic_type: dynamic_type) }

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
