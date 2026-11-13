module Sitemaps
  # A fixed list of paths. No lastmod: these pages have no single update time.
  class StaticPages
    def initialize(paths:)
      @paths = paths
    end

    def key = "pages"

    def count = @paths.size

    def entries(offset:, limit:)
      @paths.slice(offset, limit).to_a.map { |path| Entry.new(path: path, lastmod: nil) }
    end

    def lastmod = nil
  end
end
