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

      sources = [
        StaticPages.new(paths: STATIC_PATHS.fetch(domain)),
        NewsPosts.new(domain: domain)
      ]
      sources.concat(books_sources) if domain == :books
      sources
    end

    def self.books_sources
      [
        RankedItems.new(key: "books", scope: ::Books::Book.catalog,
          ranking_configuration_class: ::Books::RankingConfiguration, path_prefix: "/book/"),
        RankedItems.new(key: "authors", scope: ::Books::Author.catalog,
          ranking_configuration_class: ::Books::Authors::RankingConfiguration, path_prefix: "/author/"),
        RankedLists.new(key: "lists", list_class: ::Books::List,
          ranking_configuration_class: ::Books::RankingConfiguration, path_prefix: "/lists/"),
        Sitemaps::Books::FilterPages.new
      ]
    end
    private_class_method :books_sources

    def self.find(domain, key)
      sources(domain).find { |source| source.key == key }
    end
  end
end
