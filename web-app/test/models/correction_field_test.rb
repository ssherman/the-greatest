require "test_helper"

# == Schema Information
#
# Table name: correction_fields
#
#  id            :bigint           not null, primary key
#  applied_at    :datetime
#  field_name    :string           not null
#  new_value     :jsonb
#  old_value     :jsonb
#  status        :integer          default(0), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  correction_id :bigint           not null
#
# Indexes
#
#  index_correction_fields_on_correction_id                 (correction_id)
#  index_correction_fields_on_correction_id_and_field_name  (correction_id,field_name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (correction_id => corrections.id)
#
class CorrectionFieldTest < ActiveSupport::TestCase
  setup do
    @correction = corrections(:war_and_peace_pending)
  end

  test "defaults to pending" do
    assert_predicate CorrectionField.new, :pending?
  end

  test "requires a field name" do
    field = CorrectionField.new(correction: @correction, field_name: nil)
    assert_not field.valid?
    assert_includes field.errors[:field_name].join, "can't be blank"
  end

  test "rejects a second row for the same field on one correction" do
    existing = @correction.correction_fields.first
    duplicate = CorrectionField.new(correction: @correction, field_name: existing.field_name,
      old_value: "x", new_value: "y")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:field_name].join, "has already been taken"
  end

  test "round-trips an array through new_value" do
    field = CorrectionField.create!(correction: @correction, field_name: "alternate_titles",
      old_value: [], new_value: ["Voyna i mir", "War & Peace"])
    assert_equal ["Voyna i mir", "War & Peace"], field.reload.new_value
  end

  test "round-trips an integer through new_value" do
    field = CorrectionField.create!(correction: @correction, field_name: "word_count",
      old_value: 1869, new_value: 1867)
    assert_equal 1867, field.reload.new_value
  end

  test "accepts a field name the record declares" do
    field = CorrectionField.new(correction: corrections(:war_and_peace_pending),
      field_name: "subtitle", old_value: nil, new_value: "A Novel")

    assert_predicate field, :valid?
  end

  test "rejects a field name the record does not declare" do
    field = CorrectionField.new(correction: corrections(:war_and_peace_pending),
      field_name: "slug", old_value: "war-and-peace", new_value: "hacked")

    assert_not field.valid?
    assert_includes field.errors[:field_name].join, "not correctable"
  end

  test "does not blow up validating a blank field name" do
    field = CorrectionField.new(correction: corrections(:war_and_peace_pending), field_name: nil)

    assert_not field.valid?
    assert_includes field.errors[:field_name].join, "can't be blank"
  end
end
