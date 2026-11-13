module Sitemaps
  # The /news hub followed by the published news posts for one domain, ordered
  # by id so URLs keep their file. The hub is listed only when there is a
  # published post: /news renders noindex without one, so with no posts the
  # source is empty (and the registry leaves it out).
  class NewsPosts
    HUB_PATH = "/news"

    def initialize(domain:)
      @domain = domain
    end

    def key = "news"

    def count
      posts = scope.count
      (posts > 0) ? posts + 1 : 0
    end

    def entries(offset:, limit:)
      return [] if count == 0

      hub = (offset == 0) ? [Entry.new(path: HUB_PATH, lastmod: nil)] : []
      post_offset = [offset - 1, 0].max
      post_limit = limit - hub.size
      posts = scope.offset(post_offset).limit(post_limit).pluck(:slug, :updated_at).map do |slug, updated_at|
        Entry.new(path: "/news/#{slug}", lastmod: updated_at)
      end
      hub + posts
    end

    def lastmod = scope.maximum(:updated_at)

    private

    def scope
      NewsPost.where(domain: @domain).published.order(:id)
    end
  end
end
