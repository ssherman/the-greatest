# frozen_string_literal: true

require "digest"

# Generic Redis-backed distributed rate limiter using sliding window algorithm.
# Coordinates rate limiting across multiple processes (web servers, Sidekiq workers).
#
# @example Basic usage (blocking mode)
#   limiter = DistributedRateLimiter.new(key: "api:github", limit: 60, window: 60.0)
#   limiter.acquire!  # Blocks until slot available, then returns
#
# @example Immediate mode (fail fast)
#   limiter = DistributedRateLimiter.new(key: "api:github", limit: 60, window: 60.0, mode: :immediate)
#   limiter.acquire!  # Raises RateLimitExceeded if no slot available
#
class DistributedRateLimiter
  class RateLimitExceeded < StandardError
    attr_reader :retry_after, :key

    def initialize(message, key:, retry_after:)
      super(message)
      @key = key
      @retry_after = retry_after
    end
  end

  # Lua script for atomic sliding window rate limiting.
  # Uses Redis server time to avoid clock skew issues across distributed nodes.
  # KEYS[1] = Redis key for this rate limiter
  # ARGV[1] = limit (max requests per window)
  # ARGV[2] = window_ms (window size in milliseconds)
  # ARGV[3] = consume (1 to consume a slot, 0 for read-only check)
  # Returns: [allowed (0/1), remaining, retry_after_ms]
  LUA_SCRIPT = <<~LUA
    local key = KEYS[1]
    local limit = tonumber(ARGV[1])
    local window_ms = tonumber(ARGV[2])
    local consume = tonumber(ARGV[3]) == 1

    -- Use Redis server time to avoid clock skew between distributed nodes
    local time = redis.call('TIME')
    local now_ms = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)
    local clear_before = now_ms - window_ms

    redis.call('ZREMRANGEBYSCORE', key, '-inf', clear_before)
    local count = redis.call('ZCARD', key)

    if count < limit then
      if consume then
        local member = now_ms .. ':' .. math.random(1000000, 9999999)
        redis.call('ZADD', key, now_ms, member)
        redis.call('PEXPIRE', key, window_ms + 1000)
      end
      return {1, limit - count - (consume and 1 or 0), 0}
    else
      local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
      local retry_after_ms = 0
      if oldest[2] then
        retry_after_ms = math.max(0, window_ms - (now_ms - tonumber(oldest[2])))
      end
      return {0, 0, retry_after_ms}
    end
  LUA

  attr_reader :key, :limit, :window, :mode

  # Initialize a new rate limiter.
  #
  # @param key [String] Unique identifier for this rate limit (e.g., "igdb:api")
  # @param limit [Integer] Maximum requests allowed per window
  # @param window [Float] Window size in seconds
  # @param mode [Symbol] :blocking (sleep until available) or :immediate (raise exception)
  # @param redis [ConnectionPool, Redis] Redis connection or pool (defaults to REDIS_POOL)
  # @param logger [Logger] Optional logger for debugging
  def initialize(key:, limit:, window:, mode: :blocking, redis: nil, logger: nil)
    raise ArgumentError, "key is required" if key.nil? || key.to_s.strip.empty?
    raise ArgumentError, "limit must be positive" if limit.to_i <= 0
    raise ArgumentError, "window must be positive" if window.to_f <= 0
    raise ArgumentError, "mode must be :blocking or :immediate" unless [:blocking, :immediate].include?(mode)

    @key = key.to_s
    @limit = limit.to_i
    @window = window.to_f
    @mode = mode
    @redis_pool = redis || REDIS_POOL
    @logger = logger || (defined?(Rails) ? Rails.logger : nil)
    @script_sha = nil
  end

  # Acquire a rate limit slot.
  # In blocking mode, sleeps until a slot is available.
  # In immediate mode, raises RateLimitExceeded if no slot is available.
  #
  # @return [Hash] { allowed: true, remaining: Integer, retry_after: nil }
  # @raise [RateLimitExceeded] when mode is :immediate and limit exceeded
  def acquire!
    loop do
      result = execute_lua_script(consume: true)

      return result if result[:allowed]

      if @mode == :immediate
        raise RateLimitExceeded.new(
          "Rate limit exceeded for key '#{@key}'",
          key: @key,
          retry_after: result[:retry_after]
        )
      else
        sleep_time = [result[:retry_after], 0.01].max
        @logger&.debug { "DistributedRateLimiter: Rate limit hit for '#{@key}', sleeping #{sleep_time}s" }
        do_sleep(sleep_time)
      end
    end
  end

  # Check if a request would be allowed without consuming a slot.
  #
  # @return [Hash] { allowed: Boolean, remaining: Integer, retry_after: Float|nil }
  def check
    execute_lua_script(consume: false)
  end

  # Get current usage statistics.
  #
  # @return [Hash] { count: Integer, limit: Integer, window: Float, remaining: Integer }
  def stats
    with_redis do |redis|
      # Use Redis server time for consistency with Lua script
      time = redis.time
      now_ms = (time[0] * 1000) + (time[1] / 1000)
      clear_before = now_ms - (@window * 1000).to_i

      # Clean up expired entries first (same as Lua script does)
      redis.zremrangebyscore(redis_key, "-inf", clear_before)

      count = redis.zcard(redis_key)
      {
        count: count,
        limit: @limit,
        window: @window,
        remaining: [@limit - count, 0].max
      }
    end
  end

  # Reset the rate limiter by clearing all tracked requests.
  def reset!
    with_redis do |redis|
      redis.del(redis_key)
    end
  end

  private

  def execute_lua_script(consume:)
    with_redis do |redis|
      @script_sha ||= Digest::SHA1.hexdigest(LUA_SCRIPT)

      window_ms = (@window * 1000).to_i
      consume_flag = consume ? 1 : 0

      result = begin
        redis.evalsha(
          @script_sha,
          keys: [redis_key],
          argv: [@limit, window_ms, consume_flag]
        )
      rescue Redis::CommandError => e
        if e.message.include?("NOSCRIPT")
          redis.eval(
            LUA_SCRIPT,
            keys: [redis_key],
            argv: [@limit, window_ms, consume_flag]
          )
        else
          raise
        end
      end

      parse_lua_result(result)
    end
  end

  def with_redis(&block)
    if @redis_pool.respond_to?(:with)
      @redis_pool.with(&block)
    else
      yield @redis_pool
    end
  end

  def parse_lua_result(result)
    allowed, remaining, retry_after_ms = result
    {
      allowed: allowed == 1,
      remaining: remaining.to_i,
      retry_after: retry_after_ms.to_f / 1000.0
    }
  end

  def redis_key
    "ratelimit:#{@key}"
  end

  def do_sleep(seconds)
    sleep(seconds)
  end
end
