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
  # ordinary line. Reservations split the daily cap: ordinary turns get
  # daily_fetch_cap less config.priority_reserved (itself held to 0..cap), priority
  # turns get the slice, and a priority turn past its slice falls back to an
  # ordinary reservation. A config with no priority_reserved (the publisher
  # intake's) reserves nothing. Reservations alone do not hold the cap, though:
  # a priority turn pushes the contiguous ordinary backlog back, so a line
  # reserved on one UTC day can run on the next. The hard guards are therefore on
  # actual starts, in spacing_wait: fetch_interval since the last start, and no
  # more than daily_fetch_cap starts in a UTC day (a cap of 0 holds every turn).
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
    # has not started. It must exceed the one-minute wake latency of a workflow
    # step waiting on the sweep, or the yield lapses before the step wakes. A
    # priority job that reserves and dies stops holding ordinary turns after this
    # long.
    PRIORITY_YIELD = 90

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
    # a slow fetch come due together, and this keeps them apart. Once the UTC
    # day's actual starts reach daily_fetch_cap, every turn waits for the next
    # UTC midnight. An ordinary turn also steps aside, a full interval at a
    # time, while a priority turn is due and has not started (see
    # PRIORITY_YIELD).
    def spacing_wait(priority: false)
      state = read
      wait = [state["last_start"].to_i + @config.fetch_interval - now, 0].max
      wait = [wait, next_midnight - now].max if starts_today(state) >= daily_cap
      return wait if priority || !priority_outstanding?(state)

      [wait, @config.fetch_interval].max
    end

    # A priority turn sent back by spacing_wait re-arms its protection when
    # nothing protects it (an ordinary fetch beat it to the slot), so a backlog
    # cannot win the next slot too. Only a live job calls this, so a lost one
    # still lapses after PRIORITY_YIELD.
    def hold_priority!(wait)
      state = read
      write("priority_due" => now + wait) unless priority_outstanding?(state)
    end

    def started!(priority: false)
      state = read
      day = utc_day(now)
      count = (state["start_day"] == day) ? state["start_count"].to_i : 0
      fields = {"last_start" => now, "start_day" => day, "start_count" => count + 1}
      # More priority turns reserved behind this one: protect the next, no
      # sooner than an interval from now.
      fields["priority_due"] = now + @config.fetch_interval if priority && state["priority_start"].to_i > now
      write(fields)
    end

    def block!
      Rails.logger.warn("#{self.class.name}: #{@label} blocked a fetch; " \
        "no fetches for #{@config.block_cooldown}s")
      write("blocked_until" => now + @config.block_cooldown)
    end

    private

    def daily_cap = [@config.daily_fetch_cap.to_i, 0].max

    # Held to 0..daily_cap so the slice can never grant more than the cap.
    def priority_reserved = @config.priority_reserved.to_i.clamp(0, daily_cap)

    def ordinary_cap = daily_cap - priority_reserved

    def starts_today(state) = (state["start_day"] == utc_day(now)) ? state["start_count"].to_i : 0

    def next_midnight = Time.at(now).utc.tomorrow.beginning_of_day.to_i

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

      # The earliest start still waiting is the one to protect, however far
      # ahead it is; a newer reservation only takes over once that one has
      # started or lapsed.
      due = priority_waiting?(state) ? state["priority_due"].to_i : start
      write("priority_start" => start, "priority_due" => due, "priority_day" => day, "priority_count" => count + 1)
      Reservation.new(wait: start - now, refusal: nil)
    end

    # A priority start due within one interval ahead, or up to PRIORITY_YIELD
    # seconds past, that no fetch has begun at or after.
    def priority_outstanding?(state)
      priority_waiting?(state) && state["priority_due"].to_i - now <= @config.fetch_interval
    end

    # A priority start no fetch has begun at or after, and not lapsed.
    def priority_waiting?(state)
      due = state["priority_due"].to_i
      due > state["last_start"].to_i && now - due <= PRIORITY_YIELD
    end

    # With a cap of 0 nothing is ever granted, stored day or not, so a refusal
    # still reopens at the next UTC midnight.
    def next_day_if_spent(day, count, cap)
      return Time.at(next_midnight).utc if cap <= 0
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
