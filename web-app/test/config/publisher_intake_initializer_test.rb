# frozen_string_literal: true

require "test_helper"

class PublisherIntakeInitializerTest < ActiveSupport::TestCase
  ENV_KEYS = %w[PUBLISHER_INTAKE_SOURCES PUBLISHER_INTAKE_FETCH_INTERVAL PUBLISHER_INTAKE_DAILY_FETCH_CAP].freeze

  # Reloads the initializer under the given ENV, then puts the app's config and ENV back.
  def reload_with(env)
    config = Rails.application.config.x
    saved = config.publisher_intake
    saved_env = ENV.to_h.slice(*ENV_KEYS)
    ENV_KEYS.each { |key| ENV.delete(key) }
    env.each { |key, value| ENV[key] = value }
    load Rails.root.join("config/initializers/publisher_intake.rb")
    yield config.publisher_intake
  ensure
    ENV_KEYS.each { |key| ENV.delete(key) }
    saved_env.each { |key, value| ENV[key] = value }
    config.publisher_intake = saved
  end

  test "defaults when nothing is set" do
    reload_with({}) do |s|
      assert_equal [[], 10, 2_000, 21_600, 3, 7, 28, 30, 365, 3, 30_000],
        [s.enabled_sources, s.fetch_interval, s.daily_fetch_cap, s.block_cooldown, s.fetch_attempts,
          s.run_every_days, s.reread_after_days, s.lookback_days, s.horizon_days, s.stuck_run_days, s.fetch_timeout_ms]
    end
  end

  test "sources are split, stripped and de-duplicated" do
    assert_equal %w[hachette_us macmillan_us], PublisherIntakeEnv.sources(" hachette_us, macmillan_us ,,hachette_us ")
  end

  test "no sources for nil or blank" do
    assert_equal [[], []], [PublisherIntakeEnv.sources(nil), PublisherIntakeEnv.sources("  ")]
  end

  test "the sources, interval and cap are read from the environment" do
    reload_with("PUBLISHER_INTAKE_SOURCES" => "hachette_us,macmillan_us", "PUBLISHER_INTAKE_FETCH_INTERVAL" => "20", "PUBLISHER_INTAKE_DAILY_FETCH_CAP" => "500") do |s|
      assert_equal [%w[hachette_us macmillan_us], 20, 500], [s.enabled_sources, s.fetch_interval, s.daily_fetch_cap]
    end
  end

  test "a value that is not a whole number falls back to the default and warns, never raises" do
    warnings = []
    Rails.logger.stubs(:warn).with { |message| warnings << message.to_s }

    reload_with("PUBLISHER_INTAKE_FETCH_INTERVAL" => "08x", "PUBLISHER_INTAKE_DAILY_FETCH_CAP" => "2,000") do |s|
      assert_equal [10, 2_000], [s.fetch_interval, s.daily_fetch_cap]
    end
    %w[PUBLISHER_INTAKE_FETCH_INTERVAL PUBLISHER_INTAKE_DAILY_FETCH_CAP].each do |name|
      assert warnings.any? { |w| w.include?(name) }, "expected a warning naming #{name}"
    end
  end
end
