# The counter store for ActionController rate limits.
#
# Not Rails.cache: production configures no cache_store at all, so it falls back
# to Rails' file-store default, which is per-container and wiped on every deploy.
# Redis is already running for Sidekiq.
#
# Test uses a real in-memory store rather than the environment's :null_store,
# whose #increment returns nil -- and rate_limiting only acts `if count && count > to`,
# so against a null store the limit never fires and a test for it passes without
# ever tripping it.
Rails.application.config.x.rate_limit_store =
  if Rails.env.test?
    ActiveSupport::Cache::MemoryStore.new
  else
    ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
  end
