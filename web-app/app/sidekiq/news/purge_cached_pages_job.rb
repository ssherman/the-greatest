module News
  # Drops a news post's public pages from Cloudflare's cache after a write.
  #
  # Enqueued EXPLICITLY by each write path -- never from a model callback. An
  # after_commit making an external HTTP call is a side effect its callers
  # cannot see, and would fire from rake tasks, the legacy-blog data migration
  # and every test that creates a post.
  #
  # Takes the URLs rather than a record id, unlike Reviews::PurgeCachedPageJob:
  # a destroyed post cannot be looked up and its news_post_topics rows are gone
  # with it, so the set is computed by Services::News::CachedUrls in the
  # controller while the record still exists. Both arguments are JSON-native, so
  # they survive Sidekiq's serialisation unchanged.
  class PurgeCachedPagesJob
    include Sidekiq::Job

    # Cloudflare caps a single-file purge at 100 URLs per request on this plan
    # (500 on Enterprise). PurgeService#purge_urls issues ONE request, so an
    # oversized batch fails as a whole and purges nothing -- logged, never
    # raised, i.e. near-silent. Chunking lives here rather than in PurgeService
    # because that service also backs the admin sidebar's whole-zone purge and
    # the reviews job, and neither should inherit this task's changes.
    MAX_URLS_PER_REQUEST = 100

    def perform(domain, urls)
      return if domain.blank? || urls.blank?

      # Cloudflare::Configuration#initialize RAISES when this is blank, which is
      # every development machine and CI. Check before constructing anything.
      return if ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"].blank?

      service = Cloudflare::PurgeService.new

      urls.each_slice(MAX_URLS_PER_REQUEST).map do |batch|
        result = service.purge_urls(domain.to_sym, batch)
        Rails.logger.info "News::PurgeCachedPagesJob purged #{batch.size} urls on #{domain}: #{result[:success]}"
        result
      end
    end
  end
end
