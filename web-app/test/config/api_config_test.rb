require "test_helper"

class ApiConfigTest < ActiveSupport::TestCase
  test "every tier declares a per-minute and a per-day limit" do
    limits = Rails.application.config.x.api.rate_limits

    assert_equal [:admin, :member, :system], limits.keys.sort
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

  test "the OAuth endpoints declare positive per-IP limits" do
    api = Rails.application.config.x.api

    assert_equal 10, api.oauth_register_per_minute
    assert_equal 30, api.oauth_token_per_minute
  end

  test "every configured connector CIDR parses" do
    ranges = Rails.application.config.x.api.connector_egress_ranges

    assert_equal [:anthropic], ranges.keys
    ranges.each_value do |cidrs|
      assert_not_empty cidrs
      cidrs.each { |cidr| assert_kind_of IPAddr, IPAddr.new(cidr) }
    end
  end

  test "every rate-limited window has a positive connector-range budget above its per-IP limit" do
    api = Rails.application.config.x.api
    budgets = api.connector_range_per_minute
    per_ip = {unauthenticated: api.unauthenticated_per_minute, oauth_register: api.oauth_register_per_minute, oauth_token: api.oauth_token_per_minute}

    assert_equal per_ip.keys.sort, budgets.keys.sort
    budgets.each { |window, limit| assert_operator limit, :>, per_ip.fetch(window) }
  end

  test "the admin approval lifetime is a positive duration" do
    lifetime = Rails.application.config.x.api.oauth_admin_approval_lifetime

    assert_kind_of ActiveSupport::Duration, lifetime
    assert_operator lifetime, :>, 0
  end
end
