require "test_helper"

module Services
  module DuplicateCandidates
    class RecordMergeTest < ActiveSupport::TestCase
      def setup
        @a = games_games(:resident_evil_4)
        @b = games_games(:resident_evil_4_remake)
        @c = games_games(:half_life_2)
        @type = "Games::Game"
      end

      test "marks the merged pair, repoints other pending pairs to the survivor and repoints decisions" do
        merged_pair = Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai).data
        other_pair = Flag.call(item_type: @type, ids: [@a.id, @c.id], source: :ai).data
        decision = MatchDecision.create!(finder: "F", record: @a, outcome: :matched, confidence: :high, decided_by: :ai)

        result = RecordMerge.call(item_type: @type, source_id: @a.id, target_id: @b.id)

        assert result.success?
        assert merged_pair.reload.merged?
        assert_not_nil merged_pair.resolved_at
        other_pair.reload
        assert_equal [@b.id, @c.id].minmax, [other_pair.item_a_id, other_pair.item_b_id]
        assert other_pair.pending?
        assert_equal @b.id, decision.reload.record_id
        assert_equal @type, decision.record_type
      end

      test "drops a repointed pair that would collide with an existing row" do
        Flag.call(item_type: @type, ids: [@a.id, @c.id], source: :ai)
        survivor_pair = Flag.call(item_type: @type, ids: [@b.id, @c.id], source: :ai).data

        RecordMerge.call(item_type: @type, source_id: @a.id, target_id: @b.id)

        assert_equal [survivor_pair], DuplicateCandidate.pending.to_a
      end

      test "leaves a not_duplicate pair that named the source alone" do
        row = Flag.call(item_type: @type, ids: [@a.id, @c.id], source: :ai).data
        row.update!(status: :not_duplicate)

        RecordMerge.call(item_type: @type, source_id: @a.id, target_id: @b.id)

        row.reload
        assert row.not_duplicate?
        assert_equal [@a.id, @c.id].minmax, [row.item_a_id, row.item_b_id]
      end
    end
  end
end
