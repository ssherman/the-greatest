# frozen_string_literal: true

require "test_helper"

class GoodreadsInitializersTest < ActiveSupport::TestCase
  ENV_KEYS = %w[GOODREADS_DAILY_FETCH_CAP GOODREADS_FETCH_INTERVAL GOODREADS_REBUILD_IN_FLIGHT].freeze

  # Reloads the initializers under the given ENV, then puts the app's config and ENV back.
  def reload_with(env)
    config = Rails.application.config.x
    saved_goodreads = config.goodreads
    saved_rebuild = config.goodreads_rebuild
    saved_env = ENV.to_h.slice(*ENV_KEYS)
    ENV_KEYS.each { |key| ENV.delete(key) }
    env.each { |key, value| ENV[key] = value }
    load Rails.root.join("config/initializers/goodreads.rb")
    load Rails.root.join("config/initializers/goodreads_rebuild.rb")
    yield config
  ensure
    ENV_KEYS.each { |key| ENV.delete(key) }
    saved_env.each { |key, value| ENV[key] = value }
    config.goodreads = saved_goodreads
    config.goodreads_rebuild = saved_rebuild
  end

  test "the fetch cap and interval read ENV, falling back to 1,500 and 15" do
    reload_with({}) do |config|
      assert_equal [1_500, 15, 300], [config.goodreads.daily_fetch_cap, config.goodreads.fetch_interval, config.goodreads_rebuild.in_flight]
    end

    reload_with("GOODREADS_DAILY_FETCH_CAP" => "3000", "GOODREADS_FETCH_INTERVAL" => "10", "GOODREADS_REBUILD_IN_FLIGHT" => "50") do |config|
      assert_equal [3_000, 10, 50], [config.goodreads.daily_fetch_cap, config.goodreads.fetch_interval, config.goodreads_rebuild.in_flight]
    end
  end

  test "a number with a leading zero is read as decimal, not octal" do
    reload_with("GOODREADS_FETCH_INTERVAL" => "010") do |config|
      assert_equal 10, config.goodreads.fetch_interval
    end
  end

  test "a value that is not a whole number falls back to the default and warns, never raises" do
    warnings = []
    Rails.logger.stubs(:warn).with { |message| warnings << message.to_s }

    reload_with("GOODREADS_DAILY_FETCH_CAP" => "1,500", "GOODREADS_FETCH_INTERVAL" => "", "GOODREADS_REBUILD_IN_FLIGHT" => "08x") do |config|
      assert_equal [1_500, 15, 300], [config.goodreads.daily_fetch_cap, config.goodreads.fetch_interval, config.goodreads_rebuild.in_flight]
    end
    %w[GOODREADS_DAILY_FETCH_CAP GOODREADS_REBUILD_IN_FLIGHT].each do |name|
      assert warnings.any? { |w| w.include?(name) }, "expected a warning naming #{name}"
    end
  end
end
