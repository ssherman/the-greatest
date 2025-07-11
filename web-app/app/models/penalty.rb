# == Schema Information
#
# Table name: penalties
#
#  id          :bigint           not null, primary key
#  description :text
#  dynamic     :boolean          default(FALSE), not null
#  global      :boolean          default(FALSE), not null
#  media_type  :integer          default(0), not null
#  name        :string           not null
#  type        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint
#
# Indexes
#
#  index_penalties_on_dynamic     (dynamic)
#  index_penalties_on_global      (global)
#  index_penalties_on_media_type  (media_type)
#  index_penalties_on_type        (type)
#  index_penalties_on_user_id     (user_id)
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
  has_many :list_penalties, dependent: :destroy
  has_many :lists, through: :list_penalties

  # Enums
  enum :media_type, {
    cross_media: 0,
    books: 1,
    movies: 2,
    games: 3,
    music: 4
  }

  # Validations
  validates :name, presence: true
  validates :type, presence: true
  validates :global, inclusion: {in: [true, false]}
  validates :dynamic, inclusion: {in: [true, false]}
  validates :media_type, presence: true
  validate :user_presence_for_non_global_penalties
  validate :media_type_consistency

  # Scopes
  scope :global, -> { where(global: true) }
  scope :user_specific, -> { where(global: false) }
  scope :dynamic, -> { where(dynamic: true) }
  scope :static, -> { where(dynamic: false) }
  scope :by_media_type, ->(media_type) { where(media_type: media_type) }
  scope :cross_media, -> { where(media_type: :cross_media) }

  # Public Methods
  def global?
    global
  end

  def user_specific?
    !global?
  end

  def dynamic?
    dynamic
  end

  def static?
    !dynamic?
  end

  def cross_media?
    media_type == "cross_media"
  end

  def media_specific?
    !cross_media?
  end

  # Dynamic penalty calculation method (to be overridden by subclasses)
  def calculate_penalty_value(list, ranking_configuration)
    # Default implementation returns the static value from penalty_applications
    penalty_applications.find_by(ranking_configuration: ranking_configuration)&.value || 0
  end

  private

  def user_presence_for_non_global_penalties
    if !global? && user_id.blank?
      errors.add(:user, "must be present for user-specific penalties")
    end
  end

  def media_type_consistency
    return unless media_type.present? && type.present?

    # Check if the STI type matches the media_type
    case type
    when /^Books::/
      unless media_type == "books"
        errors.add(:media_type, "must be 'books' for Books::Penalty types")
      end
    when /^Movies::/
      unless media_type == "movies"
        errors.add(:media_type, "must be 'movies' for Movies::Penalty types")
      end
    when /^Games::/
      unless media_type == "games"
        errors.add(:media_type, "must be 'games' for Games::Penalty types")
      end
    when /^Music::/
      unless media_type == "music"
        errors.add(:media_type, "must be 'music' for Music::Penalty types")
      end
    end
  end
end
