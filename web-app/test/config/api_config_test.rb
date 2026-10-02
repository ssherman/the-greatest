require "test_helper"

class ApiConfigTest < ActiveSupport::TestCase
  test "both tiers declare a per-minute and a per-day limit" do
    limits = Rails.application.config.x.api.rate_limits

    assert_equal [:member, :system], limits.keys
    limits.each_value do |tier|
      assert_operator tier.fetch(:per_minute), :>, 0
      assert_operator tier.fetch(:per_day), :>, tier.fetch(:per_minute)
    end
  end

  test "the system tier is more generous than the member tier" do
    limits = Rails.application.config.x.api.rate_limits

    assert_operator limits[:system][:per_minute], :>, limits[:member][:per_minute]
    assert_operator limits[:system][:per_day], :>, limits[:member][:per_day]
  end

  test "the unauthenticated window and the token cap are positive integers" do
    api = Rails.application.config.x.api

    assert_kind_of Integer, api.unauthenticated_per_minute
    assert_operator api.unauthenticated_per_minute, :>, 0
    assert_kind_of Integer, api.max_tokens_per_user
    assert_operator api.max_tokens_per_user, :>, 0
  end
end
