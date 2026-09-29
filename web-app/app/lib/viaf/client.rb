# frozen_string_literal: true

module Viaf
  # The VIAF client background jobs use (spec §8). AutoSuggest and cluster
  # fetches go through BaseClient behind the Gate and an :immediate pace, so
  # no worker thread sleeps and nothing calls VIAF while it is paused. A
  # closed gate, a busy pace or a Cloudflare block raises RateLimited, which
  # the job turns into a reschedule. Every answer is kept (clusters in
  # external_records by Viaf::Cluster, AutoSuggest answers in the cache for a
  # day), so a rescheduled run resumes without repeating a request, and a
  # stored cluster is read even while VIAF is paused.
  class Client
    SUGGEST_TTL = 1.day

    def initialize(base_client: nil, gate: nil, cache: Rails.cache)
      @base_client = base_client || BaseClient.new(rate_limiter: RateLimiter.new(mode: :immediate))
      @gate = gate || Gate.new
      @cache = cache
    end

    def suggest(query)
      @cache.fetch(["viaf", "suggest", query.to_s.squish.downcase], expires_in: SUGGEST_TTL) do
        Search::AutoSuggest.new(self).call(query)
      end
    end

    def cluster(viaf_id, refresh: false) = Cluster.new(self).find(viaf_id, refresh: refresh)

    def last_rate_limit = @base_client.last_rate_limit

    # BaseClient#get behind the gate: the transport AutoSuggest and Cluster call.
    def get(path, params = {})
      wait = @gate.wait_seconds
      raise Exceptions::RateLimited.new("VIAF is paused for #{wait}s", retry_after: wait) if wait

      begin
        @base_client.get(path, params)
      ensure
        @gate.observe(@base_client.last_rate_limit)
      end
    rescue ::DistributedRateLimiter::RateLimitExceeded => e
      raise Exceptions::RateLimited.new("VIAF pace busy", retry_after: [e.retry_after.to_f.ceil, 1].max)
    rescue Exceptions::BlockedError
      seconds = @gate.blocked!
      raise Exceptions::RateLimited.new("Cloudflare blocked VIAF; every VIAF call is paused for #{seconds}s", retry_after: seconds)
    end
  end
end
