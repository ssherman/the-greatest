require "test_helper"

module Services
  module EnrichmentQueue
    class ClaimTest < ActiveSupport::TestCase
      setup do
        Registry.stubs(:types).returns([EnrichmentQueueTestType])
        @user = users(:admin_user)
        @books = [books_books(:war_and_peace), books_books(:crime_and_punishment), books_books(:got)]
        @rows = @books.each_with_index.map { |book, i| ::EnrichmentRequest.create!(enrichable: book, kind: "books.test_type", reason: "missing", priority: i) }
      end

      teardown { EnrichmentQueueTestType.reset! }

      def claim(limit: 2, kind: "books.test_type") = Claim.call(kind: kind, limit: limit, user: @user)

      test "hands out the lowest priorities first under one lease token" do
        travel_to Time.zone.parse("2026-11-17 12:00") do
          data = claim.data
          assert_equal @rows.first(2).map(&:id), data[:items].map(&:id)
          assert data[:lease_token].present?
          assert_equal Time.zone.parse("2026-11-17 12:30"), data[:lease_expires_at]
          assert_equal 1, data[:remaining]
          row = @rows.first.reload
          assert_equal ["claimed", data[:lease_token], 1, @user.id], [row.status, row.lease_token, row.attempts, row.claimed_by_id]
        end
      end

      test "priority decides the order even when it disagrees with id order" do
        @rows[0].update!(priority: 30)
        @rows[1].update!(priority: 20)
        @rows[2].update!(priority: 10)
        assert_equal [@rows[2].id, @rows[1].id], claim.data[:items].map(&:id)
      end

      test "equal priorities are handed out lowest id first" do
        @rows.each { |row| row.update!(priority: 5) }
        assert_equal @rows.first(2).map(&:id), claim.data[:items].map(&:id)
      end

      test "remaining does not include the rows this call claimed" do
        data = claim(limit: 3).data
        assert_equal [3, 0], [data[:items].size, data[:remaining]]
      end

      test "two claims never share an item" do
        first, second = claim.data, claim.data
        assert_empty first[:items].map(&:id) & second[:items].map(&:id)
        assert_not_equal first[:lease_token], second[:lease_token]
      end

      test "the claim query locks with FOR UPDATE SKIP LOCKED" do
        queries = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }
        claim
        assert queries.any? { |sql| sql.include?("FOR UPDATE SKIP LOCKED") }
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      test "an expired lease is claimable again and counts as an attempt" do
        token = claim(limit: 1).data[:lease_token]
        travel 31.minutes do
          data = claim(limit: 1).data
          assert_equal [@rows.first.id], data[:items].map(&:id)
          assert_not_equal token, data[:lease_token]
          assert_equal 2, @rows.first.reload.attempts
        end
      end

      test "a row abandoned three times is closed, not handed out a fourth time" do
        @rows.first.update!(status: :claimed, attempts: 3, lease_expires_at: 1.minute.ago)
        ids = claim(limit: 3).data[:items].map(&:id)
        assert_not_includes ids, @rows.first.id
        row = @rows.first.reload
        assert_equal ["skipped", "abandoned", "system", nil, nil], [row.status, row.outcome, row.resolved_via, row.lease_token, row.lease_expires_at]
        assert_not_nil row.resolved_at
      end

      test "an item whose gap closed is closed and the batch is topped up" do
        EnrichmentQueueTestType.stubs(:still_needed?).returns(false, true, true)
        data = claim(limit: 2).data
        assert_equal @rows.last(2).map(&:id), data[:items].map(&:id)
        row = @rows.first.reload
        assert_equal ["done", "no_longer_needed", "system", nil, nil], [row.status, row.outcome, row.resolved_via, row.lease_token, row.lease_expires_at]
        assert_not_nil row.resolved_at
      end

      test "a row whose record was deleted is deleted and not handed out" do
        @rows.first.update_columns(enrichable_id: 0)
        ids = claim(limit: 3).data[:items].map(&:id)
        assert_equal @rows.last(2).map(&:id), ids
        assert_not ::EnrichmentRequest.exists?(@rows.first.id)
      end

      test "an empty queue answers no items, no token and nothing remaining" do
        ::EnrichmentRequest.where(kind: "books.test_type").delete_all
        data = claim.data
        assert_equal [[], nil, 0], data.values_at(:items, :lease_token, :remaining)
      end

      test "rows of other kinds are left alone" do
        other = ::EnrichmentRequest.create!(enrichable: books_books(:war_and_peace), kind: "books.other", reason: "missing")
        claim(limit: 25)
        assert other.reload.pending?
      end

      test "limit must be 1 to 25" do
        assert_not claim(limit: 0).success?
        assert_not claim(limit: 26).success?
        assert claim(limit: 25).success?
      end

      test "an unknown kind is a failure, not a raise" do
        result = claim(kind: "books.nope")
        assert_not result.success?
        assert result.errors.any?
      end

      test "a claim must say who is claiming" do
        assert_raises(ArgumentError) { Claim.call(kind: "books.test_type", limit: 1) }
      end

      test "a claim with no user leaves claimed_by empty" do
        data = Claim.call(kind: "books.test_type", limit: 1, user: nil).data
        row = data[:items].sole.reload
        assert_equal ["claimed", nil], [row.status, row.claimed_by_id]
      end
    end
  end
end
