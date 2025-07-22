# == Schema Information
#
# Table name: penalty_applications
#
#  id                       :bigint           not null, primary key
#  value                    :integer          default(0), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  penalty_id               :bigint           not null
#  ranking_configuration_id :bigint           not null
#
# Indexes
#
#  index_penalty_applications_on_penalty_and_config        (penalty_id,ranking_configuration_id) UNIQUE
#  index_penalty_applications_on_penalty_id                (penalty_id)
#  index_penalty_applications_on_ranking_configuration_id  (ranking_configuration_id)
#
# Foreign Keys
#
#  fk_rails_...  (penalty_id => penalties.id)
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id)
#
class PenaltyApplication < ApplicationRecord
  # Associations
  belongs_to :penalty, inverse_of: :penalty_applications
  belongs_to :ranking_configuration, inverse_of: :penalty_applications

  # Validations
  validates :penalty_id, presence: true, uniqueness: {scope: :ranking_configuration_id}
  validates :ranking_configuration_id, presence: true
  validates :value, presence: true, numericality: {greater_than_or_equal_to: 0, less_than_or_equal_to: 100}
  validate :penalty_and_configuration_compatibility

  # Public Methods

  # Clone this penalty application for inheritance
  def clone_for_inheritance(new_ranking_configuration)
    PenaltyApplication.new(
      penalty: penalty,
      ranking_configuration: new_ranking_configuration,
      value: value
    )
  end

  private

  def penalty_and_configuration_compatibility
    return unless penalty && ranking_configuration

    # Check if penalty STI type is compatible with ranking configuration
    penalty_type = penalty.type
    config_type = ranking_configuration.type

    # Global::Penalty works with any configuration
    return if penalty_type == "Global::Penalty"

    # Check media-specific penalty compatibility
    case penalty_type
    when /^Books::/
      unless config_type.start_with?("Books::")
        errors.add(:penalty, "books penalty cannot be applied to #{config_type} configuration")
      end
    when /^Movies::/
      unless config_type.start_with?("Movies::")
        errors.add(:penalty, "movies penalty cannot be applied to #{config_type} configuration")
      end
    when /^Games::/
      unless config_type.start_with?("Games::")
        errors.add(:penalty, "games penalty cannot be applied to #{config_type} configuration")
      end
    when /^Music::/
      unless config_type.start_with?("Music::")
        errors.add(:penalty, "music penalty cannot be applied to #{config_type} configuration")
      end
    end
  end
end
