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
  #
  # The first request of a fetch never waits: a busy pace reschedules the
  # job instead. A redirect hop is different — it waits for its slot, at
  # most about a minute and only for a merged cluster, because rescheduling
  # it would repeat the already-spent 301 forever.
  #
  # A forced (refresh: true) fetch is paced the same way, and the pace allows
  # only 2 requests a minute: a run that needs three fresh clusters cannot
  # get them all in one attempt and is rescheduled. Without REFRESH_WINDOW
  # that reschedule would ask `refresh: true` again and refetch the same
  # clusters it already has, forever refusing the one it hasn't reached yet.
  # `cluster` downgrades `refresh` to false for a cluster fetched within the
  # window, so a rescheduled attempt of the same run reads what an earlier
  # attempt already fetched instead of spending a request on it again.
  class Client
    SUGGEST_TTL = 1.day
    REFRESH_WINDOW = 1.day

    def initialize(base_client: nil, gate: nil, cache: Rails.cache)
      @base_client = base_client || BaseClient.new(
        rate_limiter: RateLimiter.new(mode: :immediate),
        redirect_rate_limiter: RateLimiter.new(mode: :blocking)
      )
      @gate = gate || Gate.new
      @cache = cache
    end

    def suggest(query)
      @cache.fetch(["viaf", "suggest", query.to_s.squish.downcase], expires_in: SUGGEST_TTL) do
        Search::AutoSuggest.new(self).call(query)
      end
    end

    # A forced re-run refetches a cluster at most once a day, so a
    # rescheduled attempt of the same run reads what the earlier attempt
    # fetched instead of refetching it every time.
    def cluster(viaf_id, refresh: false)
      refresh &&= !recently_fetched?(viaf_id)
      Cluster.new(self).find(viaf_id, refresh: refresh)
    end

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

    private

    def recently_fetched?(viaf_id)
      ::ExternalRecord.where(source: :viaf, source_id: viaf_id.to_s, schema_version: Distiller::SCHEMA_VERSION)
        .where("fetched_at > ?", REFRESH_WINDOW.ago).exists?
    end
  end
end
