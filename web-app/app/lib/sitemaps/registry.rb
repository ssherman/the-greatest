module Sitemaps
  # Which sources each site publishes. Sources are built fresh on every call so
  # tests that stub Thresholds (or the gate) take effect.
  module Registry
    PAGE_SIZE = 50_000

    STATIC_PATHS = {
      books: %w[/ /authors /lists /categories /countries /news],
      # Books /rankings is deliberately absent: it renders noindex.
      music: %w[/ /albums /songs /artists /lists /albums/lists /songs/lists /rankings /news],
      games: %w[/ /lists /rankings /news]
    }.freeze

    def self.page_size = PAGE_SIZE

    # Child files a source spans, at least one. The index advertises exactly
    # this many and the controller serves exactly this many; keep it the only copy.
    def self.page_count(source)
      [(source.count / page_size.to_f).ceil, 1].max
    end

    def self.sources(domain)
      return [] unless STATIC_PATHS.key?(domain)
      return [] if domain == :books && !::Books::PublicIndexing.enabled?

      [
        StaticPages.new(paths: STATIC_PATHS.fetch(domain)),
        NewsPosts.new(domain: domain)
      ]
    end

    def self.find(domain, key)
      sources(domain).find { |source| source.key == key }
    end
  end
end
