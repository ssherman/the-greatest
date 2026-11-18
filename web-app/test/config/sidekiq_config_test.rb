# frozen_string_literal: true

require "test_helper"
# Only the Sidekiq server process loads this; the test builds a Config by hand.
require "sidekiq/capsule"

# Renders config/sidekiq.yml the way Sidekiq's CLI does (ERB, then YAML), so the
# thread count can be checked against a given environment without starting Sidekiq.
class SidekiqConfigTest < ActiveSupport::TestCase
  def sidekiq_config(env)
    original = ENV.to_h
    ENV.delete("SIDEKIQ_CONCURRENCY")
    env.each { |k, v| ENV[k] = v }
    YAML.safe_load(ERB.new(Rails.root.join("config/sidekiq.yml").read, trim_mode: "-").result, permitted_classes: [Symbol])
  ensure
    ENV.replace(original)
  end

  test "concurrency comes from SIDEKIQ_CONCURRENCY" do
    assert_equal 25, sidekiq_config("SIDEKIQ_CONCURRENCY" => "25")[:concurrency]
  end

  test "concurrency stays 5 when SIDEKIQ_CONCURRENCY is unset" do
    assert_equal 5, sidekiq_config({})[:concurrency]
  end

  test "the publisher_fetch capsule is one thread on its own queue" do
    config = Sidekiq::Config.new
    Sidekiq.stubs(:configure_server).yields(config)
    Sidekiq::Cron::Job.stubs(:load_from_hash)
    load Rails.root.join("config/initializers/sidekiq.rb")

    capsule = config.capsules["publisher_fetch"]
    assert_equal [1, %w[publisher_fetch]], [capsule.concurrency, capsule.queues]
  end
end
