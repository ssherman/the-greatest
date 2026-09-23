require "test_helper"

module Services
  module DuplicateCandidates
    class FlagTest < ActiveSupport::TestCase
      def setup
        @a = games_games(:resident_evil_4)
        @b = games_games(:resident_evil_4_remake)
        @c = games_games(:half_life_2)
        @type = "Games::Game"
      end

      test "creates a pending row with the ids in ascending order whatever order they arrive in" do
        row = Flag.call(item_type: @type, ids: [@b.id, @a.id], source: :ai, evidence: {reason: "same title"}).data

        assert row.persisted?
        assert row.pending?
        assert row.raised_by_ai?
        assert_equal [@a.id, @b.id].minmax, [row.item_a_id, row.item_b_id]
        assert_equal 1, row.occurrences
        assert_equal({"reason" => "same title"}, row.evidence)
      end

      test "returns success with nil data and writes nothing when both ids are the same record" do
        assert_no_difference("DuplicateCandidate.count") do
          result = Flag.call(item_type: @type, ids: [@a.id, @a.id], source: :ai)
          assert result.success?
          assert_nil result.data
        end
      end

      test "on a pending pair bumps occurrences and merges evidence instead of creating a second row" do
        row = assert_difference("DuplicateCandidate.count", 1) do
          Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai, evidence: {reason: "first"})
          Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :identifier_collision, evidence: {identifier: "igdb 1"}).data
        end

        assert_equal 2, row.occurrences
        assert_equal({"reason" => "first", "identifier" => "igdb 1"}, row.evidence)
        assert row.raised_by_ai?, "the first source is kept"
      end

      test "merging evidence unions a repeated array key and lets the newer value win on a repeated scalar key" do
        Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai, evidence: {reason: "first", sources: ["ai"]})

        row = Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai, evidence: {reason: "second", sources: ["identifier", "ai"]}).data

        assert_equal "second", row.evidence["reason"]
        assert_equal ["ai", "identifier"], row.evidence["sources"]
      end

      test "never reopens a pair a human ruled not a duplicate" do
        row = Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai).data
        row.update!(status: :not_duplicate, resolved_at: Time.current, resolved_by: users(:admin_user))

        again = Flag.call(item_type: @type, ids: [@b.id, @a.id], source: :ai, evidence: {reason: "again"}).data

        assert_equal row, again
        assert again.reload.not_duplicate?
        assert_equal 1, again.occurrences
        assert_equal({}, again.evidence)
      end

      test "leaves a merged pair alone" do
        row = Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai).data
        row.update!(status: :merged)

        again = Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai).data

        assert again.merged?
        assert_equal 1, again.occurrences
      end

      test "an invalid pair write raises instead of returning a failure result" do
        assert_raises(ActiveRecord::RecordInvalid) do
          Flag.call(item_type: nil, ids: [@a.id, @b.id], source: :ai)
        end
      end

      test "fails without writing when an id is missing" do
        assert_no_difference("DuplicateCandidate.count") do
          result = Flag.call(item_type: @type, ids: [@a.id, nil], source: :bulk_verify)

          refute result.success?
          assert_nil result.data
          assert_match(/two ids/, result.errors.first)
        end
      end

      test "a concurrent insert of the same pair is retried once and lands on the existing row" do
        existing = Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai).data
        fresh = ::DuplicateCandidate.new(item_type: @type, item_a_id: [@a.id, @b.id].min, item_b_id: [@a.id, @b.id].max)
        fresh.stubs(:save!).raises(ActiveRecord::RecordNotUnique, "duplicate key")
        ::DuplicateCandidate.expects(:find_or_initialize_by).twice.returns(fresh, existing)

        result = Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :bulk_verify, evidence: {reason: "again"})

        assert result.success?
        assert_equal existing, result.data
        assert_equal 2, existing.reload.occurrences
      end

      test "a second failure on the retry propagates" do
        fresh = ::DuplicateCandidate.new(item_type: @type, item_a_id: [@a.id, @b.id].min, item_b_id: [@a.id, @b.id].max)
        fresh.stubs(:save!).raises(ActiveRecord::RecordNotUnique, "duplicate key")
        ::DuplicateCandidate.expects(:find_or_initialize_by).twice.returns(fresh, fresh)

        assert_raises(ActiveRecord::RecordNotUnique) { Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai) }
      end

      test "a validation failure that the retry cannot cure still raises" do
        assert_raises(ActiveRecord::RecordInvalid) { Flag.call(item_type: "", ids: [@a.id, @b.id], source: :ai) }
      end
    end
  end
end
