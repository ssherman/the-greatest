# frozen_string_literal: true

module Viaf
  # Whether VIAF may be called now (spec §8). Held in Redis so every worker
  # sees it; two things close it:
  # - A Cloudflare block (403): an hour, doubling on each repeat up to a day.
  #   Retrying a block did not recover it within 9.5 minutes and may extend
  #   the ban, so nothing calls VIAF until the pause ends. A real VIAF answer
  #   (one carrying budget headers) resets the doubling.
  # - The day's budget running low (under LOW_BUDGET requests left): an hour.
  # One hash, so the two share a clock and a low budget never shortens a block.
  class Gate
    KEY = "viaf:pause"
    FIRST_BLOCK = 3600
    MAX_BLOCK = 86_400
    LOW_BUDGET = 50
    LOW_BUDGET_PAUSE = 3600
    # How long the doubling is remembered after the last write.
    MEMORY = 2 * MAX_BLOCK

    def initialize(redis: nil)
      @redis = redis || REDIS_POOL
    end

    # Seconds until VIAF may be called, or nil when it may be called now.
    def wait_seconds
      remaining = state["until"].to_i - now
      remaining.positive? ? remaining : nil
    end

    # Records a Cloudflare block. Returns the pause in seconds.
    def blocked!
      previous = state["block_seconds"].to_i
      seconds = previous.positive? ? [previous * 2, MAX_BLOCK].min : FIRST_BLOCK
      Rails.logger.warn("Viaf::Gate: Cloudflare blocked VIAF; pausing every VIAF call for #{seconds}s")
      write("block_seconds" => seconds)
      pause_for(seconds)
      seconds
    end

    # Records a 429 (VIAF's own rate limit, not Cloudflare's block): the
    # day's budget is spent, or an edge rate limit tripped. Returns the pause
    # in seconds; never shortens a longer block already in effect.
    def rate_limited!
      pause_for(LOW_BUDGET_PAUSE)
      LOW_BUDGET_PAUSE
    end

    # Reads the budget headers of the last response
    # (Viaf::BaseClient#last_rate_limit). A response without them came from
    # Cloudflare, not VIAF, and changes nothing.
    def observe(rate_limit)
      left = [rate_limit&.dig(:remaining), rate_limit&.dig(:remaining_day)].compact.min
      return if left.nil?

      write("block_seconds" => 0)
      pause_for(LOW_BUDGET_PAUSE) if left < LOW_BUDGET
    end

    private

    def pause_for(seconds)
      target = now + seconds
      write("until" => target) if target > state["until"].to_i
    end

    def state = with_redis { |redis| redis.hgetall(KEY) }

    def write(fields)
      with_redis do |redis|
        fields.each { |field, value| redis.hset(KEY, field, value.to_s) }
        redis.expire(KEY, MEMORY)
      end
    end

    def now = Time.current.to_i

    def with_redis(&block)
      @redis.respond_to?(:with) ? @redis.with(&block) : yield(@redis)
    end
  end
end
