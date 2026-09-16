# frozen_string_literal: true

module Books
  module OpenLibrary
    # Implements only the Redis hash commands Books::OpenLibrary::CircuitBreaker
    # issues, backed by a plain Hash, with redis-rb's return types (strings from
    # hgetall, integers from hincrby) so tests exercise real breaker behaviour.
    # CI has no Redis service, so REDIS_POOL must never be touched in tests --
    # this stands in for it. Shared by circuit_breaker_test.rb and
    # base_client_test.rb.
    class FakeRedis
      def initialize
        @data = {}
      end

      def hgetall(key)
        (@data[key] || {}).dup
      end

      def hincrby(key, field, amount)
        hash = (@data[key] ||= {})
        new_value = (hash[field] || "0").to_i + amount
        hash[field] = new_value.to_s
        new_value
      end

      def hset(key, field, value)
        hash = (@data[key] ||= {})
        hash[field] = value.to_s
      end

      def expire(key, _seconds)
        true
      end

      def del(key)
        @data.delete(key) ? 1 : 0
      end
    end
  end
end
