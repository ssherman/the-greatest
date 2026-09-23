require "test_helper"

class DuplicateCandidateTest < ActiveSupport::TestCase
  def setup
    @a = games_games(:resident_evil_4)
    @b = games_games(:resident_evil_4_remake)
    @c = games_games(:half_life_2)
    @type = "Games::Game"
  end

  test "not_duplicate? is true only for a pair a human dismissed" do
    assert_not DuplicateCandidate.not_duplicate?(item_type: @type, ids: [@a.id, @b.id])
    row = ::Services::DuplicateCandidates::Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai).data
    assert_not DuplicateCandidate.not_duplicate?(item_type: @type, ids: [@b.id, @a.id])

    row.update!(status: :not_duplicate)

    assert DuplicateCandidate.not_duplicate?(item_type: @type, ids: [@b.id, @a.id])
  end

  test "the database refuses a pair whose ids are out of order" do
    assert_raises(ActiveRecord::StatementInvalid) do
      DuplicateCandidate.insert_all([{item_type: @type, item_a_id: @b.id, item_b_id: @a.id, source: 2, status: 0, created_at: Time.current, updated_at: Time.current}])
    end
  end

  test "ids_in_order rejects an out-of-order pair and allows the same pair in order" do
    smaller, larger = [@a.id, @b.id].minmax

    out_of_order = DuplicateCandidate.new(item_type: @type, item_a_id: larger, item_b_id: smaller, source: :ai)
    assert_not out_of_order.valid?
    assert_includes out_of_order.errors[:item_b_id], "must be greater than item_a_id"

    in_order = DuplicateCandidate.new(item_type: @type, item_a_id: smaller, item_b_id: larger, source: :ai)
    assert in_order.valid?
  end

  test "item_type and item_a_id must be present" do
    missing_type = DuplicateCandidate.new(item_type: nil, item_a_id: @a.id, item_b_id: @b.id, source: :ai)
    assert_not missing_type.valid?
    assert_includes missing_type.errors[:item_type], "can't be blank"

    missing_a = DuplicateCandidate.new(item_type: @type, item_a_id: nil, item_b_id: @b.id, source: :ai)
    assert_not missing_a.valid?
    assert_includes missing_a.errors[:item_a_id], "can't be blank"
  end

  test "a second row for the same ordered pair is invalid on item_b_id" do
    row = ::Services::DuplicateCandidates::Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai).data

    dupe = DuplicateCandidate.new(item_type: @type, item_a_id: row.item_a_id, item_b_id: row.item_b_id, source: :ai)

    assert_not dupe.valid?
    assert_includes dupe.errors[:item_b_id], "has already been taken"
  end

  test "for_type scopes to the given item_type" do
    games_row = ::Services::DuplicateCandidates::Flag.call(item_type: "Games::Game", ids: [@a.id, @b.id], source: :ai).data

    assert_includes DuplicateCandidate.for_type("Games::Game"), games_row
    assert_not_includes DuplicateCandidate.for_type("Books::Book"), games_row
  end

  test "newest_first orders by created_at descending" do
    # The newer row is created FIRST (lower id) so a scope that accidentally
    # orders by id instead of created_at cannot coincidentally pass.
    newer = DuplicateCandidate.create!(item_type: @type, item_a_id: [@a.id, @b.id].min, item_b_id: [@a.id, @b.id].max, source: :ai, created_at: 1.day.ago)
    older = DuplicateCandidate.create!(item_type: @type, item_a_id: [@b.id, @c.id].min, item_b_id: [@b.id, @c.id].max, source: :ai, created_at: 2.days.ago)

    assert_equal [newer, older], DuplicateCandidate.newest_first.where(id: [newer.id, older.id]).to_a
  end
end
