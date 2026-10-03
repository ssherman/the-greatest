# The cache the Wikidata and VIAF clients keep lookups in: labels and
# country codes for 30 days, VIAF AutoSuggest answers for a day.
#
# Not Rails.cache: production configures no cache_store, so Rails.cache is
# a per-container file store wiped on every deploy, and the author backfill
# runs for days across deploys. Redis is already running for Sidekiq.
# Switching the global cache_store instead would change music and games,
# which are live.
#
# namespace is load-bearing, as in rate_limit_store.rb: RedisCacheStore#clear
# runs a bare flushdb without one, and this is Sidekiq's database.
#
# Test: a null store, as Rails.cache is there, so no lookup leaks between tests.
Rails.application.config.x.external_api_cache =
  if Rails.env.test?
    ActiveSupport::Cache::NullStore.new
  else
    ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
      namespace: "external-api"
    )
  end
