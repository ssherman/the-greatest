# frozen_string_literal: true

# Runs daily. When the local Wikidata copy has been rebuilt from a newer dump
# than the last one seen, re-checks recent books and authors that found no
# match (Services::Wikidata::Recheck). Off unless
# config.x.wikidata.recheck_after_refresh is on. An unavailable service raises
# and Sidekiq retries; the dump date is stored only after the re-check ran.
class Wikidata::RecheckAfterRefreshJob
  include Sidekiq::Job

  sidekiq_options retry: 3

  CACHE_KEY = "wikidata:recheck:last_dump_date"

  def perform
    return unless Rails.application.config.x.wikidata.recheck_after_refresh

    dump_date = ::Wikidata::Service.new.get("/version")["dump_date"].to_s
    return if dump_date.blank?

    cache = Rails.application.config.x.external_api_cache
    return if cache.read(CACHE_KEY) == dump_date

    ::Services::Wikidata::Recheck.call(dump_date: dump_date, apply: true)
    cache.write(CACHE_KEY, dump_date)
  end
end
