require "test_helper"

module Services
  module Api
    class LibraryBudgetTest < ActiveSupport::TestCase
      NOW = Time.utc(2026, 11, 16, 10, 30, 15)

      setup do
        @user = users(:regular_user)
        @other = users(:editor_user)
      end

      test "reserving 10 leaves 990" do
        result = LibraryBudget.reserve(@user, 10, now: NOW)

        assert result.ok?
        assert_equal 990, result.remaining
        assert_equal 1_000, result.limit
        assert_equal Time.utc(2026, 11, 17), result.reset_at
        assert_equal 990, LibraryBudget.remaining(@user, now: NOW)
      end

      test "an over-budget reservation is refused, rolled back, and leaves the budget intact" do
        assert LibraryBudget.reserve(@user, 990, now: NOW).ok?

        refused = LibraryBudget.reserve(@user, 20, now: NOW)
        refute refused.ok?
        assert_equal 10, refused.remaining
        assert_equal 10, LibraryBudget.remaining(@user, now: NOW)

        last = LibraryBudget.reserve(@user, 10, now: NOW)
        assert last.ok?
        assert_equal 0, last.remaining
      end

      test "release gives changes back" do
        LibraryBudget.reserve(@user, 10, now: NOW)
        assert_nil LibraryBudget.release(@user, 5, now: NOW)

        assert_equal 995, LibraryBudget.remaining(@user, now: NOW)
      end

      test "releasing more than was reserved never inflates the budget" do
        LibraryBudget.reserve(@user, 3, now: NOW)
        LibraryBudget.release(@user, 10, now: NOW)

        assert_equal 1_000, LibraryBudget.remaining(@user, now: NOW)
        assert LibraryBudget.reserve(@user, 1_000, now: NOW).ok?
        refute LibraryBudget.reserve(@user, 1, now: NOW).ok?
      end

      test "the next UTC day starts at the full limit" do
        LibraryBudget.reserve(@user, 400, now: NOW)

        assert_equal 1_000, LibraryBudget.remaining(@user, now: Time.utc(2026, 11, 17, 0, 0, 1))
      end

      test "users do not share a count" do
        LibraryBudget.reserve(@user, 400, now: NOW)

        assert_equal 1_000, LibraryBudget.remaining(@other, now: NOW)
      end

      test "a store whose increment returns nil fails open" do
        Rails.application.config.x.rate_limit_store.stubs(:increment).returns(nil)

        result = LibraryBudget.reserve(@user, 5, now: NOW)

        assert result.ok?
        assert_equal 1_000, result.remaining
      end

      test "the limit is read from config at call time" do
        Rails.application.config.x.api.stubs(:library_changes_per_day).returns(5)

        refute LibraryBudget.reserve(@user, 6, now: NOW).ok?
        assert_equal 5, LibraryBudget.remaining(@user, now: NOW)
      end
    end
  end
end
