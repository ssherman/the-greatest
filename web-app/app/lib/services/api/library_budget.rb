# frozen_string_literal: true

module Services
  module Api
    # Daily budget of book changes one member may make through the API, counted
    # per CHANGE (a batch of 50 costs 50), per user and UTC day, on the same
    # store as RateLimiter. Controllers reserve before writing and release what
    # a failed write did not use.
    class LibraryBudget
      Reservation = Struct.new(:ok, :remaining, :limit, :reset_at, keyword_init: true) do
        def ok? = ok
      end

      def self.reserve(user, count, now: Time.current)
        limit = limit()
        reset_at = day_end(now)
        total = store.increment(key(user, now), count, expires_in: (reset_at - now).ceil + 1)

        # nil is a store outage (RedisCacheStore's failsafe): fail open, like RateLimiter.
        return Reservation.new(ok: true, remaining: limit, limit: limit, reset_at: reset_at) if total.nil?

        if total > limit
          store.decrement(key(user, now), count)
          Reservation.new(ok: false, remaining: [limit - (total - count), 0].max, limit: limit, reset_at: reset_at)
        else
          Reservation.new(ok: true, remaining: limit - total, limit: limit, reset_at: reset_at)
        end
      end

      # Gives back unused changes. A release larger than what was reserved is
      # clamped at zero: left negative it would inflate every later budget.
      def self.release(user, count, now: Time.current)
        total = store.decrement(key(user, now), count)
        store.increment(key(user, now), -total) if total&.negative?
        nil
      end

      def self.remaining(user, now: Time.current)
        [limit - store.read(key(user, now), raw: true).to_i, 0].max
      end

      def self.limit = Rails.application.config.x.api.library_changes_per_day

      def self.store = Rails.application.config.x.rate_limit_store

      def self.day_end(now) = now.utc.beginning_of_day + 1.day

      def self.key(user, now) = "api:library:u:#{user.id}:d:#{now.utc.to_date.iso8601}"

      private_class_method :limit, :store, :day_end, :key
    end
  end
end
