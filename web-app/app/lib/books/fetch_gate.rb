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
  # Priority lane. A reader adding one book must not wait behind a backlog
  # that was handed out hours ahead, so a priority reservation (reserve(priority:
  # true)) takes the earliest start the interval allows and never touches the
  # ordinary line. The daily cap is split so the two together still hold it:
  # ordinary turns get daily_fetch_cap less config.priority_reserved, priority
  # turns get the slice, and a priority turn past its slice falls back to an
  # ordinary reservation. A config with no priority_reserved (the publisher
  # intake's) reserves nothing, so its gate behaves as it always did. Spacing
  # between real fetches is still enforced when a fetch starts (spacing_wait), so
  # no mix of the two lanes can put two fetches closer than fetch_interval.
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

    # How long ordinary turns step aside for a priority turn that is due and
    # has not started. A priority job that reserves and dies stops holding them
    # after this long.
    PRIORITY_YIELD = 60

    # config responds to fetch_interval, daily_fetch_cap and block_cooldown.
    # label names the caller in the block's log line.
    def initialize(key:, config:, label:, redis: nil)
      @key = key
      @config = config
      @label = label
      @redis = redis || REDIS_POOL
    end

    def reserve(priority: false)
      state = read
      return refuse(:blocked) if state["blocked_until"].to_i > now

      (priority && reserve_priority(state)) || reserve_ordinary(state)
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

    # The time a refused reservation of the same kind could succeed: the
    # block's end while blocked, else the start of the next UTC day when the
    # newest day's cap is spent, else nil (a reservation would be granted). A
    # priority turn is refused only when its slice and the ordinary line are
    # both spent, so it reopens when the first of them does.
    def reopens_at(priority: false)
      state = read
      blocked = state["blocked_until"].to_i
      return Time.at(blocked) if blocked > now

      ordinary = next_day_if_spent(state["day"], state["day_count"], ordinary_cap)
      return ordinary unless priority && ordinary && priority_reserved.positive?

      slice = next_day_if_spent(state["priority_day"], state["priority_count"], priority_reserved)
      slice && [ordinary, slice].min
    end

    # Seconds until fetch_interval has passed since the last fetch actually
    # began. A turn only promises a start time: jobs held up by a deploy or
    # a slow fetch come due together, and this keeps them apart. An ordinary
    # turn also steps aside, a full interval at a time, while a priority turn
    # is due and has not started (see PRIORITY_YIELD).
    def spacing_wait(priority: false)
      state = read
      wait = [state["last_start"].to_i + @config.fetch_interval - now, 0].max
      return wait if priority || !priority_outstanding?(state)

      [wait, @config.fetch_interval].max
    end

    def started!(priority: false)
      fields = {"last_start" => now}
      # The latest reserved priority start is the next one to protect.
      latest = read["priority_start"].to_i
      fields["priority_due"] = latest if priority && latest > now
      write(fields)
    end

    def block!
      Rails.logger.warn("#{self.class.name}: #{@label} blocked a fetch; " \
        "no fetches for #{@config.block_cooldown}s")
      write("blocked_until" => now + @config.block_cooldown)
    end

    private

    def ordinary_cap = [@config.daily_fetch_cap - priority_reserved, 0].max

    def priority_reserved = @config.priority_reserved.to_i

    def reserve_ordinary(state)
      # Counted against the UTC day the fetch starts on, not the day it was
      # reserved: a line that runs past midnight fills the next day's cap,
      # rather than letting that day take a full cap of its own on top.
      # Starts only move forward, so one day's count is all there is to keep.
      start = [now, state["next_start"].to_i].max
      day = utc_day(start)
      count = (state["day"] == day) ? state["day_count"].to_i : 0
      return refuse(:daily_cap) if count >= ordinary_cap

      write("next_start" => start + @config.fetch_interval, "day" => day, "day_count" => count + 1)
      Reservation.new(wait: start - now, refusal: nil)
    end

    # nil when the slice is spent or none is set aside: the caller falls back to
    # an ordinary reservation.
    def reserve_priority(state)
      return unless priority_reserved.positive?

      interval = @config.fetch_interval
      start = [now, state["last_start"].to_i + interval, state["priority_start"].to_i + interval].max
      day = utc_day(start)
      count = (state["priority_day"] == day) ? state["priority_count"].to_i : 0
      return if count >= priority_reserved

      # The earliest start still waiting is the one to protect; a newer
      # reservation only takes over once that one has started or lapsed.
      due = priority_outstanding?(state) ? state["priority_due"].to_i : start
      write("priority_start" => start, "priority_due" => due, "priority_day" => day, "priority_count" => count + 1)
      Reservation.new(wait: start - now, refusal: nil)
    end

    # A priority start due within one interval ahead, or up to PRIORITY_YIELD
    # seconds past, that no fetch has begun at or after.
    def priority_outstanding?(state)
      due = state["priority_due"].to_i
      due > state["last_start"].to_i && due - now <= @config.fetch_interval && now - due <= PRIORITY_YIELD
    end

    def next_day_if_spent(day, count, cap)
      return if day.blank? || count.to_i < cap

      reopens = Date.strptime(day, "%Y%m%d").next_day.in_time_zone("UTC").beginning_of_day
      reopens if reopens.to_i > now
    end

    def utc_day(epoch) = Time.at(epoch).utc.strftime("%Y%m%d")

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
