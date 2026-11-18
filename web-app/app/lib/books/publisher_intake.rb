# frozen_string_literal: true

module Books
  # Shared wiring for publisher intake: its settings, one pacing gate per
  # source, and the page fetcher client. Each call builds a new object; the
  # state lives in Redis, so nothing needs memoizing.
  module PublisherIntake
    def self.settings = Rails.application.config.x.publisher_intake

    # A source's own line, cap and block: one publisher being blocked or spent
    # for the day never slows another. redis: is for tests.
    def self.gate_for(source_key, redis: nil)
      Books::FetchGate.new(key: "publisher_intake:fetch:#{source_key}", config: settings, label: source_key, redis: redis)
    end

    # Its own breaker, so intake failures never open the circuit that
    # Goodreads fetching depends on.
    def self.client(breaker: nil)
      PageFetcher::Client.new(
        breaker: breaker || Books::OpenLibrary::CircuitBreaker.new(
          key: "page_fetcher:publisher_intake", failure_threshold: 5, cooldown: 60
        )
      )
    end
  end
end
