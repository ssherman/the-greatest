# == Schema Information
#
# Table name: cleared_fields
#
#  id             :bigint           not null, primary key
#  clearable_type :string           not null
#  cleared_via    :integer          not null
#  field_name     :string           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  clearable_id   :bigint           not null
#  cleared_by_id  :bigint
#
# Indexes
#
#  index_cleared_fields_on_clearable_and_field_name  (clearable_type,clearable_id,field_name) UNIQUE
#  index_cleared_fields_on_cleared_by_id             (cleared_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (cleared_by_id => users.id) ON DELETE => nullify
#
# A field a person blanked on purpose through the admin UI or the admin API.
# Enrichment readers (HumanClearedFields, FactSheet#year, ApplyBookFacts) treat
# a row as "leave this blank", so a refill does not undo the clear. One row per
# record and field; setting a value again deletes the row.
class ClearedField < ApplicationRecord
  CLEARABLE = {
    "Books::Book" => %w[subtitle first_published_year original_language_id],
    "Books::Author" => %w[birth_year death_year]
  }.freeze

  enum :cleared_via, {admin_ui: 0, api: 1}

  belongs_to :clearable, polymorphic: true
  belongs_to :cleared_by, class_name: "User", optional: true

  validates :field_name, presence: true, uniqueness: {scope: [:clearable_type, :clearable_id]}
  validates :cleared_via, presence: true

  # Blank means nil, or a string that is empty after strip. 0 is a value.
  def self.blank_value?(value)
    value.nil? || (value.respond_to?(:strip) && value.strip.empty?)
  end

  # Moves source's cleared rows to target for a merge: a row follows only when
  # target's field is still blank and target has no row for it; any other row is
  # left behind for the source's dependent: :delete_all. Returns the count moved.
  def self.carry_over(source:, target:)
    taken = target.cleared_fields.pluck(:field_name)
    moved = 0
    source.cleared_fields.each do |row|
      next if taken.include?(row.field_name) || !blank_value?(target.public_send(row.field_name))

      row.update!(clearable: target)
      taken << row.field_name
      moved += 1
    end
    moved
  end
end
