# == Schema Information
#
# Table name: list_penalties
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  list_id    :bigint           not null
#  penalty_id :bigint           not null
#
# Indexes
#
#  index_list_penalties_on_list_and_penalty  (list_id,penalty_id) UNIQUE
#  index_list_penalties_on_list_id           (list_id)
#  index_list_penalties_on_penalty_id        (penalty_id)
#
# Foreign Keys
#
#  fk_rails_...  (list_id => lists.id)
#  fk_rails_...  (penalty_id => penalties.id)
#
class ListPenalty < ApplicationRecord
  # Associations
  belongs_to :list
  belongs_to :penalty

  # Validations
  validates :list_id, presence: true, uniqueness: {scope: :penalty_id}
  validates :penalty_id, presence: true
  validate :list_and_penalty_compatibility

  # Scopes
  scope :by_penalty_type, ->(type) { joins(:penalty).where(penalties: {type: type}) }
  scope :global_penalties, -> { joins(:penalty).where(penalties: {global: true}) }
  scope :user_penalties, -> { joins(:penalty).where(penalties: {global: false}) }
  scope :dynamic_penalties, -> { joins(:penalty).where(penalties: {dynamic: true}) }
  scope :static_penalties, -> { joins(:penalty).where(penalties: {dynamic: false}) }

  # Public Methods
  def global_penalty?
    penalty.global?
  end

  def user_penalty?
    penalty.user_specific?
  end

  def dynamic_penalty?
    penalty.dynamic?
  end

  def static_penalty?
    penalty.static?
  end

  private

  def list_and_penalty_compatibility
    return unless list && penalty

    # Check if penalty media type is compatible with list type
    penalty_media_type = penalty.media_type
    list_type = list.type

    case penalty_media_type
    when "cross_media"
      # Cross-media penalties work with any list
      nil
    when "books"
      unless list_type.start_with?("Books::")
        errors.add(:penalty, "books penalty cannot be applied to #{list_type} list")
      end
    when "movies"
      unless list_type.start_with?("Movies::")
        errors.add(:penalty, "movies penalty cannot be applied to #{list_type} list")
      end
    when "games"
      unless list_type.start_with?("Games::")
        errors.add(:penalty, "games penalty cannot be applied to #{list_type} list")
      end
    when "music"
      unless list_type.start_with?("Music::")
        errors.add(:penalty, "music penalty cannot be applied to #{list_type} list")
      end
    end
  end
end
