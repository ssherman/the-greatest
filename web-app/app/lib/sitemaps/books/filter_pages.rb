module Sitemaps
  module Books
    # Books filter pages worth indexing: one category, one country, or one
    # category plus one country, each with enough ranked books. Thin pages stay
    # out. Counts come from RankedBooksQuery so they agree with what the page
    # itself renders. Fixed order (categories by id, countries by id, pairs by
    # [category_id, country_id]) so URLs keep their file from day to day. The
    # list is a few thousand rows, so it is built once per instance.
    class FilterPages
      def initialize(single_minimum: Sitemaps::Thresholds.filter_single, pair_minimum: Sitemaps::Thresholds.filter_pair)
        @single_minimum = single_minimum
        @pair_minimum = pair_minimum
      end

      def key = "filters"

      def count = paths.size

      def entries(offset:, limit:)
        paths.slice(offset, limit).to_a.map { |path| Entry.new(path: path, lastmod: nil) }
      end

      def lastmod = nil

      private

      def paths
        @paths ||= build_paths
      end

      def build_paths
        rc = ::Books::RankingConfiguration.default_primary
        return [] unless rc

        categories = ::Books::Category.active.order(:id).index_by(&:id)
        countries = ::Books::Country.filterable.order(:id).index_by(&:id)

        category_counts = ::Books::RankedBooksQuery.counts_by_category(ranking_configuration: rc, category_ids: categories.keys)
        country_counts = ::Books::RankedBooksQuery.counts_by_country(ranking_configuration: rc)
        pair_counts = ::Books::RankedBooksQuery.counts_by_category_and_country(ranking_configuration: rc, category_ids: categories.keys)

        category_paths = categories.values.select { |c| category_counts.fetch(c.id, 0) >= @single_minimum }
          .map { |c| ::Books::FilterPath.call(categories: [c]) }
        country_paths = countries.values.select { |c| country_counts.fetch(c.id, 0) >= @single_minimum }
          .map { |c| ::Books::FilterPath.call(countries: [c]) }
        pair_paths = pair_counts.select { |(category_id, country_id), n| n >= @pair_minimum && categories.key?(category_id) && countries.key?(country_id) }
          .keys.sort
          .map { |category_id, country_id| ::Books::FilterPath.call(categories: [categories[category_id]], countries: [countries[country_id]]) }

        category_paths + country_paths + pair_paths
      end
    end
  end
end
