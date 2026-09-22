require "test_helper"

class DuplicateCandidateTest < ActiveSupport::TestCase
  def setup
    @a = games_games(:resident_evil_4)
    @b = games_games(:resident_evil_4_remake)
    @c = games_games(:half_life_2)
    @type = "Games::Game"
  end

  test "flag! creates a pending row with the ids in ascending order whatever order they arrive in" do
    row = DuplicateCandidate.flag!(item_type: @type, ids: [@b.id, @a.id], source: :ai, evidence: {reason: "same title"})

    assert row.persisted?
    assert row.pending?
    assert row.raised_by_ai?
    assert_equal [@a.id, @b.id].minmax, [row.item_a_id, row.item_b_id]
    assert_equal 1, row.occurrences
    assert_equal({"reason" => "same title"}, row.evidence)
  end

  test "flag! returns nil and writes nothing when both ids are the same record" do
    assert_no_difference("DuplicateCandidate.count") { assert_nil DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @a.id], source: :ai) }
  end

  test "flag! on a pending pair bumps occurrences and merges evidence instead of creating a second row" do
    row = assert_difference("DuplicateCandidate.count", 1) do
      DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai, evidence: {reason: "first"})
      DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :identifier_collision, evidence: {identifier: "igdb 1"})
    end

    assert_equal 2, row.occurrences
    assert_equal({"reason" => "first", "identifier" => "igdb 1"}, row.evidence)
    assert row.raised_by_ai?, "the first source is kept"
  end

  test "flag! merging evidence unions a repeated array key and lets the newer value win on a repeated scalar key" do
    DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai, evidence: {reason: "first", sources: ["ai"]})

    row = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai, evidence: {reason: "second", sources: ["identifier", "ai"]})

    assert_equal "second", row.evidence["reason"]
    assert_equal ["ai", "identifier"], row.evidence["sources"]
  end

  test "flag! never reopens a pair a human ruled not a duplicate" do
    row = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai)
    row.update!(status: :not_duplicate, resolved_at: Time.current, resolved_by: users(:admin_user))

    again = DuplicateCandidate.flag!(item_type: @type, ids: [@b.id, @a.id], source: :ai, evidence: {reason: "again"})

    assert_equal row, again
    assert again.reload.not_duplicate?
    assert_equal 1, again.occurrences
    assert_equal({}, again.evidence)
  end

  test "flag! leaves a merged pair alone" do
    row = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai)
    row.update!(status: :merged)

    again = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai)

    assert again.merged?
    assert_equal 1, again.occurrences
  end

  test "not_duplicate? is true only for a pair a human dismissed" do
    assert_not DuplicateCandidate.not_duplicate?(item_type: @type, ids: [@a.id, @b.id])
    row = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai)
    assert_not DuplicateCandidate.not_duplicate?(item_type: @type, ids: [@b.id, @a.id])

    row.update!(status: :not_duplicate)

    assert DuplicateCandidate.not_duplicate?(item_type: @type, ids: [@b.id, @a.id])
  end

  test "record_merge marks the merged pair, repoints other pending pairs to the survivor and repoints decisions" do
    merged_pair = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai)
    other_pair = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @c.id], source: :ai)
    decision = MatchDecision.create!(finder: "F", record: @a, outcome: :matched, confidence: :high, decided_by: :ai)

    DuplicateCandidate.record_merge(item_type: @type, source_id: @a.id, target_id: @b.id)

    assert merged_pair.reload.merged?
    assert_not_nil merged_pair.resolved_at
    other_pair.reload
    assert_equal [@b.id, @c.id].minmax, [other_pair.item_a_id, other_pair.item_b_id]
    assert other_pair.pending?
    assert_equal @b.id, decision.reload.record_id
    assert_equal @type, decision.record_type
  end

  test "record_merge drops a repointed pair that would collide with an existing row" do
    DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @c.id], source: :ai)
    survivor_pair = DuplicateCandidate.flag!(item_type: @type, ids: [@b.id, @c.id], source: :ai)

    DuplicateCandidate.record_merge(item_type: @type, source_id: @a.id, target_id: @b.id)

    assert_equal [survivor_pair], DuplicateCandidate.pending.to_a
  end

  test "record_merge leaves a not_duplicate pair that named the source alone" do
    row = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @c.id], source: :ai)
    row.update!(status: :not_duplicate)

    DuplicateCandidate.record_merge(item_type: @type, source_id: @a.id, target_id: @b.id)

    row.reload
    assert row.not_duplicate?
    assert_equal [@a.id, @c.id].minmax, [row.item_a_id, row.item_b_id]
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
    row = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai)

    dupe = DuplicateCandidate.new(item_type: @type, item_a_id: row.item_a_id, item_b_id: row.item_b_id, source: :ai)

    assert_not dupe.valid?
    assert_includes dupe.errors[:item_b_id], "has already been taken"
  end

  test "for_type scopes to the given item_type" do
    games_row = DuplicateCandidate.flag!(item_type: "Games::Game", ids: [@a.id, @b.id], source: :ai)

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
