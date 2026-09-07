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
    # namespace is load-bearing, not cosmetic: ActiveSupport::Cache::RedisCacheStore#clear
    # runs a bare `redis.flushdb` when no namespace is configured, and only does a
    # scoped `delete_matched` when one is set. This store points at the same
    # REDIS_URL Sidekiq uses for its queues, and a `.clear` call already exists in the
    # global `setup` block in test/test_helper.rb (plus several individual controller
    # tests) -- harmless today only because the test environment resolves to the
    # MemoryStore branch above. Do not remove this as noise; removing it turns any
    # future `.clear` call in a non-test environment into a full wipe of Sidekiq's
    # database.
    ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
      namespace: "rate-limit"
    )
  end
