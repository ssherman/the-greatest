# == Schema Information
#
# Table name: ranking_archives
#
#  id                              :bigint           not null, primary key
#  captured_at                     :datetime         not null
#  description                     :text
#  hidden                          :boolean          default(FALSE), not null
#  item_ids                        :bigint           default([]), not null, is an Array
#  items_count                     :integer          default(0), not null
#  name                            :string           not null
#  period                          :date
#  positions                       :integer          default([]), not null, is an Array
#  scores                          :decimal(10, 2)   default([]), not null, is an Array
#  slug                            :string           not null
#  type                            :string           not null
#  created_at                      :datetime         not null
#  updated_at                      :datetime         not null
#  legacy_ranking_configuration_id :integer
#  ranking_configuration_id        :bigint
#
# Indexes
#
#  index_ranking_archives_on_config_and_period                (ranking_configuration_id,period) UNIQUE WHERE (period IS NOT NULL)
#  index_ranking_archives_on_legacy_config                    (legacy_ranking_configuration_id) UNIQUE WHERE (legacy_ranking_configuration_id IS NOT NULL)
#  index_ranking_archives_on_ranking_configuration_id         (ranking_configuration_id)
#  index_ranking_archives_on_type_and_hidden_and_captured_at  (type,hidden,captured_at)
#  index_ranking_archives_on_type_and_slug                    (type,slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id) ON DELETE => nullify
#
# A frozen ranking kept as one flat row instead of thousands of ranked_items rows.
# The three parallel arrays and items_count are written once, at creation, and
# never change; only the presentation fields (name, slug, description, hidden) do.
class RankingArchive < ApplicationRecord
  SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  FROZEN_ATTRIBUTES = %w[item_ids positions scores items_count].freeze

  belongs_to :ranking_configuration, optional: true

  scope :visible, -> { where(hidden: false) }
  scope :newest_first, -> { order(captured_at: :desc, id: :desc) }
  # Every column except the three arrays, so listings never load thousands of ids.
  scope :summaries, -> { select(column_names - %w[item_ids positions scores]) }

  before_validation :set_items_count, on: :create
  before_validation :set_slug, on: :create

  validates :name, presence: true
  validates :slug, presence: true, format: {with: SLUG_FORMAT}, uniqueness: {scope: :type}
  validates :captured_at, presence: true
  validates :item_ids, presence: true
  validate :arrays_have_equal_length
  validate :period_is_first_of_month
  validate :arrays_are_frozen, on: :update

  def self.item_type
    raise NotImplementedError, "#{name} must define item_type"
  end

  def item_class
    self.class.item_type.constantize
  end

  def origin
    if legacy_ranking_configuration_id.present?
      :legacy
    elsif period.present?
      :monthly
    else
      :manual
    end
  end

  private

  def set_items_count
    self.items_count = item_ids.size
  end

  def set_slug
    return if slug.present?

    base = name.to_s.parameterize.presence || "archive"
    candidate = base
    suffix = 2
    while self.class.unscoped.exists?(type: self.class.sti_name, slug: candidate)
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end
    self.slug = candidate
  end

  def arrays_have_equal_length
    return if item_ids.size == positions.size && item_ids.size == scores.size

    errors.add(:base, "item_ids, positions and scores must be the same length")
  end

  def period_is_first_of_month
    return if period.blank? || period.day == 1

    errors.add(:period, "must be the first day of a month")
  end

  def arrays_are_frozen
    changed_frozen = FROZEN_ATTRIBUTES.select { |attribute| attribute_changed?(attribute) }
    return if changed_frozen.empty?

    errors.add(:base, "#{changed_frozen.to_sentence} cannot change after creation")
  end
end
