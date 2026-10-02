# frozen_string_literal: true

require "sidekiq"
require "sidekiq-cron"
# Sidekiq::Queue, ScheduledSet and RetrySet (used by Services::Books::Authors::QueuedChain
# and its test) live here, not in the base "sidekiq" require. Initializers run on every
# boot regardless of eager_load, so this is available in dev/test even though app/lib is
# autoloaded lazily there.
require "sidekiq/api"

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

if Rails.env.test?
  # Sidekiq logs "connecting to Redis" at INFO on every client connection, which in
  # the test environment means one line per parallel worker (24+) on every run.
  Sidekiq.configure_client do |config|
    config.logger.level = Logger::WARN
  end
end
