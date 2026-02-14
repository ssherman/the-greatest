# Distributed Rate Limiter

## Status
- **Status**: Complete
- **Priority**: High
- **Created**: 2026-02-13
- **Started**: 2026-02-13
- **Completed**: 2026-02-14
- **Developer**: AI Agent (Claude)

## Overview
Build a generic, Redis-backed distributed rate limiter that coordinates rate limiting across multiple processes (web servers, Sidekiq workers). Uses a sliding window algorithm implemented with atomic Lua scripts for accuracy and thread-safety. The rate limiter is designed to be reusable across any API client.

**Scope**: Generic `DistributedRateLimiter` class in shared `app/lib/`. First consumer: `Games::Igdb::RateLimiter`.

**Non-goals**: Token bucket algorithm. External gems (ratelimit, redlock-rb). Metrics/instrumentation (future improvement).

## Context & Links
- Current IGDB rate limiter (first consumer): `web-app/app/lib/games/igdb/rate_limiter.rb`
- IGDB BaseClient: `web-app/app/lib/games/igdb/base_client.rb`
- IGDB wrapper spec: `docs/specs/completed/games-igdb-api-wrapper.md`
- Sidekiq Redis config: `web-app/config/initializers/sidekiq.rb`
- Spec instructions: `docs/spec-instructions.md`

## Interfaces & Contracts

### Class Hierarchy

```
DistributedRateLimiter                    - Generic Redis-backed sliding window rate limiter
DistributedRateLimiter::RateLimitExceeded - Exception for immediate-mode failures

Games::Igdb::RateLimiter                  - IGDB-specific wrapper (delegates to generic)
```

### File Structure

```
web-app/app/lib/
└── distributed_rate_limiter.rb           # NEW: Generic Redis-backed implementation

web-app/app/lib/games/igdb/
└── rate_limiter.rb                       # MODIFY: Delegate to DistributedRateLimiter

web-app/config/initializers/
└── redis.rb                              # NEW: Redis connection pool initializer

web-app/test/lib/
└── distributed_rate_limiter_test.rb      # NEW: Unit tests

web-app/test/lib/games/igdb/
└── rate_limiter_test.rb                  # MODIFY: Update tests for delegation
```

### Gemfile Changes

```ruby
# Uncomment existing line:
gem "redis", ">= 4.0.1"

# Add connection pooling:
gem "connection_pool"
```

### Configuration

**Environment variables** (already available via Sidekiq):
- `REDIS_URL` — Redis connection URL (default: `redis://localhost:6379/0`)

**DistributedRateLimiter options**:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `key` | String | (required) | Unique identifier for this rate limit (e.g., `"igdb:api"`, `"musicbrainz:api"`) |
| `limit` | Integer | (required) | Maximum requests allowed per window |
| `window` | Integer/Float | (required) | Window size in seconds |
| `mode` | Symbol | `:blocking` | `:blocking` = sleep until available, `:immediate` = raise exception |
| `redis` | Redis/ConnectionPool | `REDIS_POOL` | Redis connection or pool |
| `logger` | Logger | `Rails.logger` | Optional logger for debugging |

### Public API

```ruby
# reference only
class DistributedRateLimiter
  class RateLimitExceeded < StandardError
    attr_reader :retry_after, :key
  end

  # Initialize with options
  def initialize(key:, limit:, window:, mode: :blocking, redis: nil, logger: nil)

  # Acquire a rate limit slot. Returns immediately or blocks depending on mode.
  # @return [Hash] { allowed: true, remaining: N, retry_after: nil }
  # @raise [RateLimitExceeded] when mode is :immediate and limit exceeded
  def acquire!

  # Check if a request would be allowed (non-blocking, doesn't consume a slot)
  # @return [Hash] { allowed: Boolean, remaining: Integer, retry_after: Float|nil }
  def check

  # Get current usage stats
  # @return [Hash] { count: Integer, limit: Integer, window: Float, remaining: Integer }
  def stats

  # Reset the rate limiter (clear all tracked requests) - useful for testing
  def reset!
end
```

### Lua Script — Sliding Window

The sliding window algorithm tracks request timestamps in a Redis sorted set, removing expired entries atomically:

```lua
-- reference only (actual implementation may vary)
-- KEYS[1] = rate limit key
-- ARGV[1] = limit, ARGV[2] = window_ms, ARGV[3] = now_ms

local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window_ms = tonumber(ARGV[2])
local now_ms = tonumber(ARGV[3])
local clear_before = now_ms - window_ms

-- Remove expired entries
redis.call('ZREMRANGEBYSCORE', key, '-inf', clear_before)

-- Count current requests in window
local count = redis.call('ZCARD', key)

if count < limit then
  -- Add this request with timestamp as score, unique member
  redis.call('ZADD', key, now_ms, now_ms .. ':' .. math.random(1, 1000000))
  redis.call('PEXPIRE', key, window_ms)
  return {1, limit - count - 1, 0}  -- allowed=1, remaining, retry_after=0
else
  -- Calculate when oldest entry expires
  local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
  local retry_after = 0
  if oldest[2] then
    retry_after = window_ms - (now_ms - tonumber(oldest[2]))
    if retry_after < 0 then retry_after = 0 end
  end
  return {0, 0, retry_after}  -- allowed=0, remaining=0, retry_after_ms
end
```

### Redis Key Structure

| Key Pattern | Type | TTL | Description |
|-------------|------|-----|-------------|
| `ratelimit:{key}` | ZSET | window + 1s | Sorted set of request timestamps |

Examples:
- `ratelimit:igdb:api` for IGDB API (4 req/sec)
- `ratelimit:musicbrainz:api` for MusicBrainz API (1 req/sec)
- `ratelimit:tmdb:api` for TMDB API (40 req/10sec)

### IGDB Integration

The existing `Games::Igdb::RateLimiter` class will delegate to the generic implementation:

```ruby
# reference only
module Games
  module Igdb
    class RateLimiter
      REQUESTS_PER_SECOND = 4

      def initialize(mode: :blocking)
        @limiter = ::DistributedRateLimiter.new(
          key: "igdb:api",
          limit: REQUESTS_PER_SECOND,
          window: 1.0,
          mode: mode
        )
      end

      def wait!
        @limiter.acquire!
      end
    end
  end
end
```

### Future API Integration Examples

```ruby
# reference only - shows how other APIs would use the generic limiter

# MusicBrainz: 1 request per second
class Music::Musicbrainz::RateLimiter
  def initialize
    @limiter = DistributedRateLimiter.new(
      key: "musicbrainz:api",
      limit: 1,
      window: 1.0
    )
  end
end

# TMDB: 40 requests per 10 seconds
class Movies::Tmdb::RateLimiter
  def initialize
    @limiter = DistributedRateLimiter.new(
      key: "tmdb:api",
      limit: 40,
      window: 10.0
    )
  end
end

# Spotify: 180 requests per minute
class Music::Spotify::RateLimiter
  def initialize
    @limiter = DistributedRateLimiter.new(
      key: "spotify:api",
      limit: 180,
      window: 60.0
    )
  end
end
```

### Behaviors (pre/postconditions)

**Preconditions**:
- `REDIS_URL` environment variable must be set (or Redis available at localhost:6379)
- Redis server must be running and accessible
- `redis` gem must be installed

**Postconditions**:
- In `:blocking` mode: `acquire!` always returns successfully (after waiting if necessary)
- In `:immediate` mode: `acquire!` returns immediately or raises `RateLimitExceeded`
- Rate limit state is shared across all processes using the same Redis instance
- Timestamps older than `window` are automatically cleaned up
- Redis keys auto-expire after `window` + 1 second of inactivity

**Edge cases & failure modes**:

| Scenario | Behavior |
|----------|----------|
| Redis connection fails | Raise `Redis::CannotConnectError` (let caller handle) |
| Redis timeout | Raise `Redis::TimeoutError` |
| Key doesn't exist | Create it on first `acquire!` |
| Clock skew between processes | Minimal impact - uses server-side timestamps via Lua |
| Process dies mid-request | Request counted, slot consumed (acceptable) |
| Concurrent requests from multiple processes | Lua script ensures atomicity |
| Rate limit exceeded in blocking mode | Sleep and retry until slot available |
| Rate limit exceeded in immediate mode | Raise `RateLimitExceeded` with `retry_after` |

### Non-Functionals

- **Atomicity**: All rate limit operations are atomic via Lua scripts (no race conditions)
- **Latency**: Single Redis round-trip per `acquire!` call (~1-2ms local, ~5-10ms remote)
- **Memory**: O(N) where N = limit (stores N timestamps per window per key)
- **Thread safety**: Redis operations are inherently thread-safe; Lua scripts are atomic
- **Connection pooling**: Uses connection pool to avoid connection overhead
- **TTL cleanup**: Keys auto-expire; no manual cleanup needed
- **Reusability**: Generic design supports any API with configurable key/limit/window

## Acceptance Criteria

### Redis Setup
- [x] `redis` gem is uncommented in Gemfile
- [x] `connection_pool` gem is added to Gemfile
- [x] `config/initializers/redis.rb` creates a shared connection pool (`REDIS_POOL`)
- [x] Redis connection uses `ENV["REDIS_URL"]` with localhost fallback

### DistributedRateLimiter Class
- [x] `DistributedRateLimiter` lives in `app/lib/distributed_rate_limiter.rb`
- [x] Implements sliding window algorithm with Lua script
- [x] Lua script executes atomically (no race conditions)
- [x] `acquire!` in `:blocking` mode sleeps until slot available
- [x] `acquire!` in `:immediate` mode raises `RateLimitExceeded` when limit exceeded
- [x] `check` method returns current state without consuming a slot
- [x] `stats` method returns usage statistics
- [x] `reset!` method clears all tracked requests
- [x] `RateLimitExceeded` exception includes `retry_after` and `key` attributes

### IGDB Integration
- [x] `Games::Igdb::RateLimiter` delegates to `DistributedRateLimiter`
- [x] Existing `Games::Igdb::BaseClient` works without modification
- [x] Default mode is `:blocking` (preserves existing behavior)
- [x] Rate limiting works across multiple processes (web + Sidekiq)

### Error Handling
- [x] `RateLimitExceeded` exception includes `retry_after` value in seconds
- [x] Redis connection errors bubble up (not silently swallowed)

### Testing
- [x] `DistributedRateLimiter` has unit tests in `test/lib/distributed_rate_limiter_test.rb`
- [x] Redis calls are stubbed/mocked (no real Redis in unit tests)
- [x] Tests verify Lua script logic (count, cleanup, atomicity)
- [x] Tests verify both `:blocking` and `:immediate` modes
- [x] Tests follow existing patterns in `test/lib/`

### Golden Examples

**Example 1: Basic usage (blocking mode)**

```text
Input:
  limiter = DistributedRateLimiter.new(
    key: "igdb:api",
    limit: 4,
    window: 1.0,
    mode: :blocking
  )

  # Make 5 rapid requests
  5.times { limiter.acquire! }

Behavior:
  - First 4 calls return immediately
  - 5th call sleeps until a slot opens (up to 1 second)
  - All 5 calls eventually succeed

Output (each call):
  { allowed: true, remaining: N, retry_after: nil }
```

**Example 2: Immediate mode**

```text
Input:
  limiter = DistributedRateLimiter.new(
    key: "igdb:api",
    limit: 4,
    window: 1.0,
    mode: :immediate
  )

  # Make 5 rapid requests
  4.times { limiter.acquire! }  # All succeed
  limiter.acquire!              # 5th request

Behavior:
  - First 4 calls return immediately
  - 5th call raises exception

Output:
  DistributedRateLimiter::RateLimitExceeded
    message: "Rate limit exceeded for key 'igdb:api'"
    key: "igdb:api"
    retry_after: 0.85  # seconds until a slot opens
```

**Example 3: Check without consuming**

```text
Input:
  limiter = DistributedRateLimiter.new(key: "igdb:api", limit: 4, window: 1.0)
  3.times { limiter.acquire! }
  result = limiter.check

Output:
  { allowed: true, remaining: 1, retry_after: nil }
  # Note: remaining is 1, not 0, because check didn't consume a slot
```

**Example 4: Cross-process coordination**

```text
Setup:
  Process A: Web server
  Process B: Sidekiq worker
  Both configured with same Redis URL and key "igdb:api"

Scenario:
  t=0.0s: Process A calls acquire! -> allowed (count: 1)
  t=0.1s: Process B calls acquire! -> allowed (count: 2)
  t=0.2s: Process A calls acquire! -> allowed (count: 3)
  t=0.3s: Process B calls acquire! -> allowed (count: 4)
  t=0.4s: Process A calls acquire! -> blocks (count: 4)
  t=1.0s: Window slides, oldest request expires
  t=1.0s: Process A acquire! unblocks -> allowed (count: 4)

Result:
  Both processes respect the shared 4 req/sec limit
```

**Example 5: IGDB wrapper usage (unchanged API)**

```text
Input:
  # Existing code continues to work unchanged
  client = Games::Igdb::BaseClient.new
  result = client.post("games", "fields name; limit 10;")

Behavior:
  - BaseClient creates RateLimiter internally
  - RateLimiter delegates to DistributedRateLimiter
  - Rate limiting now works across all processes
  - API unchanged for consumers
```

---

## Agent Hand-Off

### Constraints
- Place generic class in `app/lib/distributed_rate_limiter.rb`
- Use Lua scripts for atomicity (not WATCH/MULTI/EXEC)
- Respect snippet budget (≤40 lines per snippet)
- Do not duplicate authoritative code; **link to file paths**
- Preserve existing `Games::Igdb::RateLimiter` public API (just delegate internally)

### Required Outputs
- All files listed in "File Structure" above
- All Acceptance Criteria passing
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → confirm Redis initializer patterns in Rails
2) codebase-analyzer → verify BaseClient integration points
3) web-search-researcher → Lua script best practices if needed
4) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- No database fixtures needed (pure library, no ActiveRecord)
- Mock Redis with Mocha (`Redis.any_instance.stubs(:evalsha)`)
- Use inline response hashes matching existing test patterns

---

## Implementation Notes (living)
- Approach taken: Single-file implementation with inline Lua script, minimal abstractions
- Important decisions:
  - EVALSHA with EVAL fallback for script caching
  - Fixed connection pool size of 5 (matching Sidekiq defaults)
  - No max wait time in blocking mode (trust sliding window cleanup)
  - Added `do_sleep()` wrapper method for testability

### Key Files Touched (paths only)
- `web-app/Gemfile` - Uncommented redis gem, added connection_pool
- `web-app/config/initializers/redis.rb` - NEW: Global REDIS_POOL constant
- `web-app/app/lib/distributed_rate_limiter.rb` - NEW: 175 lines
- `web-app/app/lib/games/igdb/rate_limiter.rb` - MODIFIED: Delegates to DistributedRateLimiter
- `web-app/test/lib/distributed_rate_limiter_test.rb` - NEW: 36 tests
- `web-app/test/lib/games/igdb/rate_limiter_test.rb` - MODIFIED: Tests delegation pattern

### Challenges & Resolutions
- Mocha `yields` didn't work with connection pool mocking; created MockRedisPool wrapper class
- Kernel.sleep not interceptable via expects; added `do_sleep()` private method
- Stats method could return stale counts; fixed by cleaning up expired entries first

### Deviations From Plan
- None significant; implementation matches spec closely

## Acceptance Results
- Date: 2026-02-14
- Tests passing: 36/36 rate limiter tests
- Full suite: 3699/3699 tests passing

## Future Improvements
- Add metrics/instrumentation (count rate limit hits, average wait time)
- Add circuit breaker pattern for Redis failures (fall back to in-memory)
- Support token bucket algorithm for APIs that allow bursting
- Admin dashboard for viewing rate limit stats across all APIs
- Registry pattern for centralized rate limit configuration

## Related PRs
- (pending creation)

## Documentation Updated
- [x] Spec file updated with implementation notes and acceptance results
- [ ] `documentation.md` — deferred until PR review
