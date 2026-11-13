module Sitemaps
  # Published news posts for one domain, ordered by id so URLs keep their file.
  class NewsPosts
    def initialize(domain:)
      @domain = domain
    end

    def key = "news"

    def count = scope.count

    def entries(offset:, limit:)
      scope.offset(offset).limit(limit).pluck(:slug, :updated_at).map do |slug, updated_at|
        Entry.new(path: "/news/#{slug}", lastmod: updated_at)
      end
    end

    def lastmod = scope.maximum(:updated_at)

    private

    def scope
      NewsPost.where(domain: @domain).published.order(:id)
    end
  end
end
