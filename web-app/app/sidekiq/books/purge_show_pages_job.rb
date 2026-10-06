# frozen_string_literal: true

# Drops promoted books' and authors' canonical pages from Cloudflare's cache
# (Goodreads import spec §9-§10). A provisional record's cached page carries
# noindex and the "not yet reviewed" notice, which must not outlive its
# approval. Copies under /rc/:id/... expire on their own, as
# Reviews::PurgeCachedPageJob explains.
class Books::PurgeShowPagesJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 5

  def perform(book_ids, author_ids = [])
    # Cloudflare::Configuration raises without it: every development machine and CI.
    return if ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"].blank?

    host = Rails.application.config.domains[:books]
    urls = ::Books::Book.where(id: book_ids).where.not(slug: nil).pluck(:slug).map { |slug| "https://#{host}/book/#{slug}" } +
      ::Books::Author.where(id: author_ids).where.not(slug: nil).pluck(:slug).map { |slug| "https://#{host}/author/#{slug}" }
    return if urls.empty?

    urls.each_slice(::Books::ReadingGoals::PurgeCachedPagesJob::MAX_URLS_PER_REQUEST) do |batch|
      ::Cloudflare::PurgeService.new.purge_urls(:books, batch)
    end
  end
end
