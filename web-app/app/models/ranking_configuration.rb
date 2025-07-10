class RankingConfiguration < ApplicationRecord
  # Associations
  belongs_to :inherited_from, class_name: "RankingConfiguration", optional: true
  belongs_to :user, optional: true
  belongs_to :primary_mapped_list, class_name: "List", optional: true
  belongs_to :secondary_mapped_list, class_name: "List", optional: true

  has_many :inherited_configurations, class_name: "RankingConfiguration", foreign_key: :inherited_from_id, dependent: :nullify
  has_many :ranked_items, dependent: :destroy
  has_many :ranked_lists, dependent: :destroy

  # Validations
  validates :name, presence: true, length: {maximum: 255}
  validates :algorithm_version, presence: true, numericality: {only_integer: true, greater_than: 0}
  validates :exponent, presence: true, numericality: {greater_than: 0, less_than_or_equal_to: 10}
  validates :bonus_pool_percentage, presence: true, numericality: {greater_than_or_equal_to: 0, less_than_or_equal_to: 100}
  validates :min_list_weight, presence: true, numericality: {only_integer: true}
  validates :list_limit, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
  validates :max_list_dates_penalty_age, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
  validates :max_list_dates_penalty_percentage, numericality: {only_integer: true, greater_than: 0, less_than_or_equal_to: 100}, allow_nil: true
  validates :primary_mapped_list_cutoff_limit, numericality: {only_integer: true, greater_than: 0}, allow_nil: true

  # Custom validations
  validate :only_one_primary_per_type, if: :primary?
  validate :global_configurations_cannot_have_user
  validate :user_configurations_cannot_be_global
  validate :inherited_from_must_be_same_type, if: :inherited_from_id?

  # Scopes
  scope :global, -> { where(global: true) }
  scope :user_specific, -> { where(global: false) }
  scope :primary, -> { where(primary: true) }
  scope :active, -> { where(archived: false) }
  scope :published, -> { where.not(published_at: nil) }
  scope :by_type, ->(type) { where(type: type) }

  # Callbacks
  before_save :ensure_only_one_primary_per_type, if: :primary?

  # Instance methods
  def published?
    published_at.present?
  end

  def inherited?
    inherited_from_id.present?
  end

  def can_inherit_from?(other_config)
    other_config.type == type && other_config.id != id
  end

  def clone_for_inheritance
    new_config = dup
    new_config.inherited_from_id = id
    new_config.primary = false
    new_config.published_at = nil
    new_config
  end

  private

  def only_one_primary_per_type
    existing_primary = self.class.where(type: type, primary: true)
    existing_primary = existing_primary.where.not(id: id) if persisted?

    if existing_primary.exists?
      errors.add(:primary, "can only have one primary configuration per type")
    end
  end

  def global_configurations_cannot_have_user
    if global? && user_id.present?
      errors.add(:user_id, "global configurations cannot have a user")
    end
  end

  def user_configurations_cannot_be_global
    if !global? && user_id.blank?
      errors.add(:user_id, "user-specific configurations must have a user")
    end
  end

  def inherited_from_must_be_same_type
    if inherited_from && inherited_from.type != type
      errors.add(:inherited_from, "must be the same type")
    end
  end

  def ensure_only_one_primary_per_type
    return unless primary?

    self.class.where(type: type, primary: true)
      .where.not(id: id)
      .update_all(primary: false)
  end
end
