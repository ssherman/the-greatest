# frozen_string_literal: true

require "sidekiq"
require "sidekiq-cron"

Sidekiq.configure_server do |config|
  config.redis = {url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")}

  # Configure serial processing capsule
  # This ensures jobs requiring serial processing (like API rate limiting) run one at a time
  config.capsule("serial") do |cap|
    cap.concurrency = 1
    cap.queues = %w[serial]
  end

  # Load cron jobs
  schedule_file = "config/schedule.yml"

  if File.exist?(schedule_file)
    Sidekiq::Cron::Job.load_from_hash YAML.load_file(schedule_file)
  end
end

Sidekiq.configure_client do |config|
  config.redis = {url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")}
end
