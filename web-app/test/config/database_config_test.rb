# frozen_string_literal: true

require "test_helper"

# Renders config/database.yml the way Rails does (ERB, then YAML) against a
# given environment, so TLS settings can be checked without booting production.
class DatabaseConfigTest < ActiveSupport::TestCase
  def production_config(env)
    original = ENV.to_h
    %w[POSTGRES_SSLMODE LEGACY_BOOKS_SSLMODE RAILS_MAX_THREADS SIDEKIQ_CONCURRENCY].each { |k| ENV.delete(k) }
    env.each { |k, v| ENV[k] = v }
    yaml = ERB.new(Rails.root.join("config/database.yml").read).result
    YAML.safe_load(yaml, aliases: true).fetch("production")
  ensure
    ENV.replace(original)
  end

  test "production primary takes sslmode from POSTGRES_SSLMODE" do
    assert_equal "require", production_config("POSTGRES_SSLMODE" => "require").dig("primary", "sslmode")
  end

  test "legacy_books takes sslmode from LEGACY_BOOKS_SSLMODE, independent of primary" do
    c = production_config("POSTGRES_SSLMODE" => "require", "LEGACY_BOOKS_SSLMODE" => "prefer")
    assert_equal "prefer", c.dig("legacy_books", "sslmode")
    assert_equal "require", c.dig("primary", "sslmode")
  end

  test "legacy_books does not fall back to POSTGRES_SSLMODE" do
    assert production_config("POSTGRES_SSLMODE" => "require").dig("legacy_books", "sslmode").blank?
  end

  test "unset leaves sslmode blank so a connection still works on the old server" do
    assert production_config({}).dig("primary", "sslmode").blank?
  end

  test "the pool covers the Sidekiq threads plus the single-lane capsules, on both databases" do
    c = production_config("RAILS_MAX_THREADS" => "5", "SIDEKIQ_CONCURRENCY" => "25")
    assert_equal [30, 30], [c.dig("primary", "pool"), c.dig("legacy_books", "pool")]
  end

  test "the pool keeps RAILS_MAX_THREADS when it is the larger" do
    assert_equal 50, production_config("RAILS_MAX_THREADS" => "50", "SIDEKIQ_CONCURRENCY" => "10").dig("primary", "pool")
  end

  test "the pool stays 50 when neither is set" do
    assert_equal 50, production_config({}).dig("primary", "pool")
  end

  test "a blank sslmode still connects to the local server" do
    config = production_config({}).fetch("primary")
    test_config = ActiveRecord::Base.connection_db_config.configuration_hash
    merged = test_config.merge(sslmode: config["sslmode"])
    conn = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(merged)
    assert_equal 1, conn.select_value("SELECT 1")
  ensure
    conn&.disconnect!
  end
end
