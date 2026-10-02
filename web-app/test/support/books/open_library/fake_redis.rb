# frozen_string_literal: true

module Books
  module OpenLibrary
    # Implements only the Redis hash commands Books::OpenLibrary::CircuitBreaker
    # issues, backed by a plain Hash, with redis-rb's return types (strings from
    # hgetall, integers from hincrby) so tests exercise real breaker behaviour.
    # CI has no Redis service, so REDIS_POOL must never be touched in tests --
    # this stands in for it. Shared by circuit_breaker_test.rb and
    # base_client_test.rb.
    #
    # Models TTL: #expire records a real expiry time (Time.current + seconds),
    # and every command drops a key whose expiry has passed before doing
    # anything else. That makes travel/travel_to in the tests exercise expiry
    # for real, rather than treating #expire as a no-op that never lets a key
    # die -- the gap that let R118 (the circuit breaker not surviving a failed
    # half-open probe) go undetected.
    class FakeRedis
      def initialize
        @data = {}
        @expires_at = {}
      end

      def hgetall(key)
        drop_if_expired(key)
        (@data[key] || {}).dup
      end

      def hincrby(key, field, amount)
        drop_if_expired(key)
        hash = (@data[key] ||= {})
        new_value = (hash[field] || "0").to_i + amount
        hash[field] = new_value.to_s
        new_value
      end

      def hset(key, field, value)
        drop_if_expired(key)
        hash = (@data[key] ||= {})
        hash[field] = value.to_s
      end

      def expire(key, seconds)
        drop_if_expired(key)
        return false unless @data.key?(key)

        @expires_at[key] = Time.current + seconds
        true
      end

      def del(key)
        drop_if_expired(key)
        @expires_at.delete(key)
        @data.delete(key) ? 1 : 0
      end

      private

      def drop_if_expired(key)
        expires_at = @expires_at[key]
        return unless expires_at && Time.current >= expires_at

        @data.delete(key)
        @expires_at.delete(key)
      end
    end
  end
end
