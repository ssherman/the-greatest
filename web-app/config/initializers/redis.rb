# frozen_string_literal: true

require "redis"
require "connection_pool"

# Global Redis connection pool for shared rate limiting across processes.
# Uses the same REDIS_URL as Sidekiq for simplicity.
REDIS_POOL = ConnectionPool.new(size: 5, timeout: 5) do
  Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
end
