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

  # `recent` had no coverage at all before this. The trap this repo has hit
  # before: fixture ids and insertion order tend to coincide with the intended
  # sort order, so a naive ordering test can pass even when `recent` silently
  # orders by id (or not at all). Insertion order here is deliberately NOT
  # created_at order -- `newest` is inserted first (lowest id) with the most
  # recent timestamp, `oldest` second (middle id) with the oldest timestamp,
  # `middle` last (highest id) with a timestamp in between -- so id-ascending,
  # id-descending, and plain insertion order all disagree with the correct
  # created_at-desc answer. Only a `recent` that truly orders by created_at
  # produces the asserted sequence.
  test "recent orders by created_at, most recent first" do
    newest = Correction.create!(correctable: @book, user: @user, notes: "n", created_at: 1.day.ago)
    oldest = Correction.create!(correctable: @book, user: @user, notes: "o", created_at: 3.days.ago)
    middle = Correction.create!(correctable: @book, user: @user, notes: "m", created_at: 2.days.ago)

    ids = Correction.where(id: [newest.id, oldest.id, middle.id]).recent.pluck(:id)

    assert_equal [newest.id, middle.id, oldest.id], ids
  end

  # The id tiebreak matters whenever two corrections land in the same request
  # (e.g. a bulk migration import) and get identical created_at values. Without
  # it, Postgres does not promise any particular order for ties.
  test "recent breaks a created_at tie on id, higher id first" do
    tied_at = 1.hour.ago
    first_inserted = Correction.create!(correctable: @book, user: @user, notes: "a", created_at: tied_at)
    second_inserted = Correction.create!(correctable: @book, user: @user, notes: "b", created_at: tied_at)

    ids = Correction.where(id: [first_inserted.id, second_inserted.id]).recent.pluck(:id)

    assert_equal [second_inserted.id, first_inserted.id], ids
  end
end
