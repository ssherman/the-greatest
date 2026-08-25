require "test_helper"

# == Schema Information
#
# Table name: corrections
#
#  id               :bigint           not null, primary key
#  correctable_type :string           not null
#  notes            :text
#  resolution_notes :text
#  resolved_at      :datetime
#  status           :integer          default(0), not null
#  submitter_ip     :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  correctable_id   :bigint           not null
#  resolved_by_id   :bigint
#  user_id          :bigint
#
# Indexes
#
#  index_corrections_on_correctable            (correctable_type,correctable_id)
#  index_corrections_on_resolved_by_id         (resolved_by_id)
#  index_corrections_on_status_and_created_at  (status,created_at)
#  index_corrections_on_user_id                (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (resolved_by_id => users.id)
#  fk_rails_...  (user_id => users.id)
#
class CorrectionTest < ActiveSupport::TestCase
  setup do
    @book = books_books(:war_and_peace)
    @user = users(:regular_user)
  end

  test "is valid with notes and no fields" do
    correction = Correction.new(correctable: @book, user: @user, notes: "The year is wrong")
    assert_predicate correction, :valid?
  end

  test "is valid anonymously" do
    correction = Correction.new(correctable: @book, user: nil, notes: "The year is wrong")
    assert_predicate correction, :valid?
  end

  test "is invalid with neither notes nor fields" do
    correction = Correction.new(correctable: @book, notes: nil)
    assert_not correction.valid?
    assert_includes correction.errors[:base].join, "Tell us what's wrong"
  end

  test "is valid with a field and no notes" do
    correction = Correction.new(correctable: @book, notes: nil)
    correction.correction_fields.build(field_name: "title", old_value: "War and Peace", new_value: "War & Peace")
    assert_predicate correction, :valid?
  end

  test "rejects notes longer than the cap" do
    correction = Correction.new(correctable: @book, notes: "x" * (Correction::MAX_NOTES_LENGTH + 1))
    assert_not correction.valid?
    assert_includes correction.errors[:notes].join, "too long"
  end

  test "normalizes blank notes to nil" do
    correction = Correction.new(correctable: @book, notes: "   ")
    correction.correction_fields.build(field_name: "title", old_value: "a", new_value: "b")
    correction.validate
    assert_nil correction.notes
  end

  test "defaults to pending" do
    assert_predicate Correction.new, :pending?
  end
end
