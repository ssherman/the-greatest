module Sitemaps
  # Active categories whose page holds enough ranked items to be worth indexing.
  # scope is an active category relation; counts is a lambda returning
  # {category_id => ranked item count}, built by the registry from the same
  # sets the page itself shows. Ordered by id; no lastmod (category pages list
  # items, they have no content of their own).
  class RankedCategories
    def initialize(key:, scope:, counts:, path_prefix:, minimum: Sitemaps::Thresholds.filter_single)
      @key = key
      @scope = scope
      @counts = counts
      @path_prefix = path_prefix
      @minimum = minimum
    end

    attr_reader :key

    def count = slugs.size

    def entries(offset:, limit:)
      slugs.slice(offset, limit).to_a.map { |slug| Entry.new(path: "#{@path_prefix}#{slug}", lastmod: nil) }
    end

    def lastmod = nil

    private

    def slugs
      @slugs ||= begin
        counts = @counts.call
        @scope.reorder(:id).pluck(:id, :slug).filter_map do |id, slug|
          slug if counts.fetch(id, 0) >= @minimum
        end
      end
    end
  end
end
