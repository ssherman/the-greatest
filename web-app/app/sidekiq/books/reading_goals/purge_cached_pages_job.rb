module Books
  module ReadingGoals
    class PurgeCachedPagesJob
      include Sidekiq::Job

      sidekiq_options retry: 5

      MAX_URLS_PER_REQUEST = 100
      PurgeError = Class.new(StandardError)

      def perform(domain, urls)
        return if domain.blank? || urls.blank?
        return if ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"].blank?

        service = Cloudflare::PurgeService.new
        urls.each_slice(MAX_URLS_PER_REQUEST) do |batch|
          result = service.purge_urls(domain.to_sym, batch)
          Rails.logger.info "Books::ReadingGoals purge #{batch.size} URLs on #{domain}: #{result[:success]}"
          next if result[:success]

          Rails.logger.error "Books::ReadingGoals purge failed on #{domain}: #{result[:error]}"
          raise PurgeError, result[:error] || "Cloudflare purge failed"
        end
      end
    end
  end
end
