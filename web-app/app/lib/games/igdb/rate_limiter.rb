# frozen_string_literal: true

module Games
  module Igdb
    class RateLimiter
      REQUESTS_PER_SECOND = 4

      def initialize
        @timestamps = []
        @mutex = Mutex.new
      end

      def wait!
        @mutex.synchronize do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          # Remove timestamps older than 1 second
          @timestamps.reject! { |t| now - t >= 1.0 }

          if @timestamps.size >= REQUESTS_PER_SECOND
            sleep_time = 1.0 - (now - @timestamps.first)
            if sleep_time > 0
              sleep(sleep_time)
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              @timestamps.reject! { |t| now - t >= 1.0 }
            end
          end

          @timestamps << now
        end
      end
    end
  end
end
