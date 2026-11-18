# frozen_string_literal: true

module Books
  # When the next page fetch for one caller may start. Held in Redis so every
  # worker sees one line. Each reservation takes the next start time,
  # fetch_interval after the last one handed out, and counts against the cap
  # of the UTC day it starts on; a block refuses every reservation until it
  # ends. The caller waits for its start time by rescheduling itself, never by
  # sleeping. Each caller keys its own line (Goodreads, one per publisher), so
  # lines, caps and blocks never mix.
  #
  # Hash commands only, so CI's FakeRedis can stand in. Read-then-write is
  # not atomic; it needs no lock because only one job at a time per key
  # reserves (a single-concurrency capsule).
  class FetchGate
    # Outlives the cooldown and a full day's line.
    MEMORY = 2 * 86_400

    Reservation = Data.define(:wait, :refusal) do
      def granted? = refusal.nil?
    end

    Usage = Data.define(:day, :count)

    # config responds to fetch_interval, daily_fetch_cap and block_cooldown.
    # label names the caller in the block's log line.
    def initialize(key:, config:, label:, redis: nil)
      @key = key
      @config = config
      @label = label
      @redis = redis || REDIS_POOL
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

    # The UTC day of the newest reservation and how many fetches that day holds;
    # [nil, 0] when nothing is stored. The day can be tomorrow: a long line
    # reserves turns that start past midnight.
    def usage
      state = read
      return Usage.new(day: nil, count: 0) if state["day"].blank?

      Usage.new(day: Date.strptime(state["day"], "%Y%m%d"), count: state["day_count"].to_i)
    end

    # When the current block ends; nil when none was set or it has passed.
    def blocked_until
      epoch = read["blocked_until"].to_i
      Time.at(epoch) if epoch > now
    end

    # The time a refused reservation could succeed: the block's end while
    # blocked, else the start of the next UTC day when the newest day's cap is
    # spent, else nil (a reservation would be granted).
    def reopens_at
      state = read
      blocked = state["blocked_until"].to_i
      return Time.at(blocked) if blocked > now

      day = state["day"]
      return nil if day.blank? || state["day_count"].to_i < @config.daily_fetch_cap

      reopens = Date.strptime(day, "%Y%m%d").next_day.in_time_zone("UTC").beginning_of_day
      reopens if reopens.to_i > now
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
      Rails.logger.warn("#{self.class.name}: #{@label} blocked a fetch; " \
        "no fetches for #{@config.block_cooldown}s")
      write("blocked_until" => now + @config.block_cooldown)
    end

    private

    def refuse(reason) = Reservation.new(wait: nil, refusal: reason)

    def read = with_redis { |redis| redis.hgetall(@key) }

    def write(fields)
      with_redis do |redis|
        fields.each { |field, value| redis.hset(@key, field, value.to_s) }
        redis.expire(@key, MEMORY)
      end
    end

    def now = Time.current.to_i

    def with_redis(&block)
      @redis.respond_to?(:with) ? @redis.with(&block) : yield(@redis)
    end
  end
end
