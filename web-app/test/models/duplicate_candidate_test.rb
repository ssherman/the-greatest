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
end
