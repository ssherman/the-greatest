# frozen_string_literal: true

require "test_helper"

module CsvExports
  class LimitsTest < ActiveSupport::TestCase
    test "a member has no limit" do
      assert_nil Limits.limit_for(users(:regular_user))
    end

    test "a signed-in non-member gets the preview rows" do
      assert_equal 500, Limits.limit_for(users(:user_with_expired_membership))
    end

    test "no user gets the preview rows" do
      assert_equal 500, Limits.limit_for(nil)
    end
  end
end
