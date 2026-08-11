module Reviews
  # Drops one page from Cloudflare's cache after its reviews change.
  #
  # Enqueued EXPLICITLY by each write path -- never from a model callback. An
  # after_commit making an external HTTP call is a side effect its callers
  # cannot see, and would fire from rake tasks, importers and any test that
  # creates a review.
  #
  # Only the canonical /book/:slug is purged. Copies under
  # /rc/:ranking_configuration_id/book/:slug stay cached until they expire --
  # a deliberate trade against enumerating every ranking configuration.
  class PurgeCachedPageJob
    include Sidekiq::Job

    # Reviewable types that have a public, cached page worth purging, mapped to the
    # domain whose cache holds that page. The ONE source of truth for "is this type
    # purgeable" -- canonical_url dispatches on the domain this hash resolved rather
    # than re-checking reviewable_type itself, so a second entry added here without a
    # matching branch in canonical_url raises loudly (caught by any test that exercises
    # it) instead of silently resolving a domain and then returning nil forever.
    PURGEABLE = {"Books::Book" => :books}.freeze

    def perform(reviewable_type, reviewable_id)
      domain = PURGEABLE[reviewable_type]
      return if domain.nil?

      # Cloudflare::Configuration#initialize RAISES when this is blank, which is
      # every development machine and CI. Check before constructing anything.
      return if ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"].blank?

      url = canonical_url(domain, reviewable_id)
      return if url.nil?

      result = Cloudflare::PurgeService.new.purge_urls(domain, [url])
      Rails.logger.info "Reviews::PurgeCachedPageJob purged #{url}: #{result[:success]}"
      result
    end

    private

    def canonical_url(domain, reviewable_id)
      case domain
      when :books
        book = ::Books::Book.find_by(id: reviewable_id)
        return nil if book.nil? || book.slug.blank?

        "https://#{Rails.application.config.domains[:books]}/book/#{book.slug}"
      else
        raise ArgumentError, "Reviews::PurgeCachedPageJob: no canonical_url branch for domain #{domain.inspect}"
      end
    end
  end
end
