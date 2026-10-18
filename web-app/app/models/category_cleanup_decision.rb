# One proposed change to a books category from the cleanup pipeline
# (spec §4.1). Written by Services::CategoryCleanup::RulePass and ::AiPass,
# reviewed through the report, executed by ::Applier. Validations and scopes
# only; the logic lives in app/lib/services/category_cleanup/.
class CategoryCleanupDecision < ApplicationRecord
  STAGES = %w[rules locations_head locations_tail subjects_head subjects_tail sync apply genres].freeze
  SNAPSHOT_FIELDS = %w[name category_type parent_id deleted item_count].freeze

  belongs_to :category
  belongs_to :target_category, class_name: "Category", optional: true
  belongs_to :ai_chat, optional: true

  # prefix: true -- unprefixed `delete` and `merge` scopes collide with Active Record.
  enum :action, {keep: 0, rename: 1, merge: 2, retype: 3, set_parent: 4, delete: 5, split: 6}, prefix: true
  enum :decided_by, {rule: 0, ai: 1}, prefix: true
  enum :status, {proposed: 0, rejected: 1, applied: 2, stale: 3, failed: 4}

  validates :run, :action, :decided_by, presence: true
  validates :stage, inclusion: {in: STAGES}
  validates :new_name, presence: true, if: -> { proposed? && action_rename? }
  validates :target_category, presence: true, if: -> { proposed? && action_merge? }
  validates :parent_chain, presence: true, if: -> { proposed? && action_set_parent? }
  validates :new_category_type, presence: true, if: -> { proposed? && action_retype? }
  validate :split_has_a_primary, if: -> { proposed? && action_split? }

  scope :for_run, ->(run) { where(run: run) }
  # Decisions after which the category no longer exists under its own name and type.
  scope :terminal, -> { where(action: %i[merge split retype delete]) }

  def self.snapshot_of(category)
    category.attributes.slice(*SNAPSHOT_FIELDS).merge("category_type" => category.category_type)
  end

  private

  # Merging mode names the category to merge into; renaming mode names what
  # this category becomes. Spec 2026-10-17 section 4, "Combined genres".
  def split_has_a_primary
    errors.add(:base, "a split needs a target category or a new name") if target_category_id.nil? && new_name.blank?
  end
end
