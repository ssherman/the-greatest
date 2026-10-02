# frozen_string_literal: true

module Viaf
  # Start times for VIAF jobs that have to wait (spec §8, sized for the
  # increment-6 backfill). VIAF serves two requests a minute and about a
  # thousand a day, while a backfill's Wikidata misses arrive several a
  # minute. Sent back after the same short wait, a backlog of thousands
  # would retry together every half minute and fill the low queue with
  # jobs that cannot run. Each waiting job takes the next free start time
  # instead, SLOT_SECONDS after the last one given out, so a backlog of N
  # runs once each, in turn.
  #
  # Held in Redis so every worker shares one line. HINCRBY then HSET is
  # not atomic: two jobs reserving at the same moment on an empty line can
  # get the same start, and the second simply waits again.
  class Schedule
    KEY = "viaf:schedule"
    FIELD = "last"
    # An author costs one to four requests at two a minute.
    SLOT_SECONDS = 90

    def initialize(redis: nil)
      @redis = redis || REDIS_POOL
    end

    # Seconds from now until this job's start: at least not_before, and one
    # slot after every start already given out.
    def reserve(not_before:)
      floor = now + not_before.to_i
      with_redis do |redis|
        slot = redis.hincrby(KEY, FIELD, SLOT_SECONDS)
        if slot < floor
          slot = floor
          redis.hset(KEY, FIELD, slot)
        end
        redis.expire(KEY, slot - now + SLOT_SECONDS)
        slot - now
      end
    end

    # The last start given out, or nil once it has passed (no one waiting).
    def horizon
      last = with_redis { |redis| redis.hgetall(KEY)[FIELD] }.to_i
      (last > now) ? Time.zone.at(last) : nil
    end

    private

    def now = Time.current.to_i

    def with_redis(&block)
      @redis.respond_to?(:with) ? @redis.with(&block) : yield(@redis)
    end
  end
end
