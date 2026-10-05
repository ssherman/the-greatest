# frozen_string_literal: true

module Books
  module Goodreads
    # When the next Goodreads page fetch may start (Goodreads import spec §6,
    # "Politeness"). Held in Redis so every worker sees one line. Each
    # reservation takes the next start time, fetch_interval after the last one
    # handed out, and counts against the cap of the UTC day it starts on; a
    # block refuses every reservation until it ends. The caller waits for its
    # start time by rescheduling itself, never by sleeping.
    #
    # Hash commands only, so CI's FakeRedis can stand in. Read-then-write is
    # not atomic; it needs no lock because only the goodreads_fetch capsule,
    # one job at a time, reserves.
    class FetchGate
      KEY = "goodreads:fetch"
      # Outlives the cooldown and a full day's line.
      MEMORY = 2 * 86_400

      Reservation = Data.define(:wait, :refusal) do
        def granted? = refusal.nil?
      end

      def initialize(redis: nil, config: nil)
        @redis = redis || REDIS_POOL
        @config = config || Rails.application.config.x.goodreads
      end

      def reserve
        state = read
        return refuse(:blocked) if state["blocked_until"].to_i > now

        # Counted against the UTC day the fetch starts on, not the day it was
        # reserved: a line that runs past midnight fills the next day's cap,
        # rather than letting that day take a full cap of its own on top.
        # Starts only move forward, so one day's count is all there is to keep.
        start = [now, state["next_start"].to_i].max
        day = Time.at(start).utc.strftime("%Y%m%d")
        count = (state["day"] == day) ? state["day_count"].to_i : 0
        return refuse(:daily_cap) if count >= @config.daily_fetch_cap

        write("next_start" => start + @config.fetch_interval, "day" => day, "day_count" => count + 1)
        Reservation.new(wait: start - now, refusal: nil)
      end

      def blocked?
        read["blocked_until"].to_i > now
      end

      # Seconds until fetch_interval has passed since the last fetch actually
      # began. A turn only promises a start time: jobs held up by a deploy or
      # a slow fetch come due together, and this keeps them apart.
      def spacing_wait
        [read["last_start"].to_i + @config.fetch_interval - now, 0].max
      end

      def started!
        write("last_start" => now)
      end

      def block!
        Rails.logger.warn("#{self.class.name}: Goodreads blocked a fetch or served an unrecognizable page; " \
          "no fetches for #{@config.block_cooldown}s")
        write("blocked_until" => now + @config.block_cooldown)
      end

      private

      def refuse(reason) = Reservation.new(wait: nil, refusal: reason)

      def read = with_redis { |redis| redis.hgetall(KEY) }

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
end
