require "test_helper"

module Services
  module EnrichmentQueue
    class FillTest < ActiveSupport::TestCase
      setup do
        Registry.stubs(:types).returns([EnrichmentQueueTestType])
        @war, @crime = books_books(:war_and_peace), books_books(:crime_and_punishment)
        EnrichmentQueueTestType.candidate_ids = [@war.id, @crime.id]
      end

      teardown { EnrichmentQueueTestType.reset! }

      def fill(**options) = Fill.call(kind: "books.test_type", **options)

      test "inserts a pending row per candidate with the type's version and priority" do
        result = fill
        assert_equal 2, result.data[:inserted]
        row = ::EnrichmentRequest.find_by!(enrichable: @war, kind: "books.test_type")
        assert_equal ["pending", "missing", 1, @war.id], [row.status, row.reason, row.version, row.priority]
      end

      test "a second fill inserts nothing and re-opens nothing" do
        fill
        ::EnrichmentRequest.where(enrichable: @war).update!(status: :done, outcome: "applied", resolved_at: Time.current)
        result = fill
        assert_equal [0, 0], result.data.values_at(:inserted, :reopened)
        assert ::EnrichmentRequest.find_by!(enrichable: @war).done?
      end

      test "a resolved row below the type's version is re-opened when its record is still a candidate" do
        fill
        ::EnrichmentRequest.where(enrichable: [@war, @crime]).update!(status: :skipped, outcome: "nothing found", note: "n", resolved_at: Time.current)
        EnrichmentQueueTestType.stubs(:version).returns(2)
        EnrichmentQueueTestType.candidate_ids = [@war.id]
        result = fill
        assert_equal 1, result.data[:reopened]
        war = ::EnrichmentRequest.find_by!(enrichable: @war)
        assert_equal ["pending", "version", 2, 0], [war.status, war.reason, war.version, war.attempts]
        assert_nil war.outcome
        assert_nil war.resolved_at
        assert ::EnrichmentRequest.find_by!(enrichable: @crime).skipped?
      end

      test "claimed, submitted and failed rows are left alone" do
        fill
        EnrichmentQueueTestType.stubs(:version).returns(2)
        ::EnrichmentRequest.where(enrichable: @war).update!(status: :claimed, lease_expires_at: 5.minutes.from_now, lease_token: "t")
        ::EnrichmentRequest.where(enrichable: @crime).update!(status: :failed, error: "boom")
        result = fill
        assert_equal [0, 0], result.data.values_at(:inserted, :reopened)
        assert ::EnrichmentRequest.find_by!(enrichable: @war).claimed?
        assert ::EnrichmentRequest.find_by!(enrichable: @crime).failed?
      end

      test "a pending row's priority follows the type's priority" do
        fill
        ::EnrichmentRequest.where(enrichable: @war).update!(priority: 999)
        assert_equal 1, fill.data[:reprioritized]
        assert_equal @war.id, ::EnrichmentRequest.find_by!(enrichable: @war).priority
      end

      test "limit caps the candidates taken, lowest priority value first" do
        lowest, other = [@war, @crime].sort_by(&:id)
        assert_equal 1, fill(limit: 1).data[:inserted]
        assert ::EnrichmentRequest.exists?(enrichable: lowest)
        assert_not ::EnrichmentRequest.exists?(enrichable: other)
      end

      test "an unknown kind or scope is a failure" do
        assert_not Fill.call(kind: "books.nope").success?
        assert_not fill(scope: "everything").success?
      end
    end
  end
end
