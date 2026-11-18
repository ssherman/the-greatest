require "test_helper"

module Services
  module EnrichmentQueue
    class SkipTest < ActiveSupport::TestCase
      setup do
        @user = users(:admin_user)
        @row = ::EnrichmentRequest.create!(enrichable: books_books(:war_and_peace), kind: "books.test_type", reason: "missing",
          status: :claimed, lease_token: "lease-1", lease_expires_at: 10.minutes.from_now)
      end

      def skip(**overrides)
        Skip.call(request: @row, lease_token: "lease-1", reason: "no reliable source", user: @user, **overrides)
      end

      test "skips the row with the reason in note and a closed outcome, and clears the lease" do
        assert skip.success?
        @row.reload
        assert_equal ["skipped", "skipped_by_agent", "no reliable source", "api", @user.id, nil, nil],
          [@row.status, @row.outcome, @row.note, @row.resolved_via, @row.resolved_by_id, @row.lease_token, @row.lease_expires_at]
        assert @row.resolved_at.present?
      end

      test "a wrong token is a conflict and writes nothing" do
        assert_equal :conflict, skip(lease_token: "other").errors.first[:code]
        assert @row.reload.claimed?
      end

      test "a row that is not claimed is a conflict" do
        @row.update!(status: :done)
        assert_equal :conflict, skip.errors.first[:code]
      end

      test "a blank reason or one over 500 characters is invalid" do
        assert_equal :invalid, skip(reason: " ").errors.first[:code]
        assert_equal :invalid, skip(reason: "r" * 501).errors.first[:code]
        assert @row.reload.claimed?
      end

      test "a wrong token is a conflict even when the reason is blank" do
        assert_equal :conflict, skip(lease_token: "other", reason: "").errors.first[:code]
      end
    end
  end
end
