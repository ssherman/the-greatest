# frozen_string_literal: true

require "test_helper"

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
end
