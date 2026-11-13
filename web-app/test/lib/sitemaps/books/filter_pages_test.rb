require "test_helper"

module Sitemaps
  module Books
    class FilterPagesTest < ActiveSupport::TestCase
      setup do
        @rc = ranking_configurations(:books_global)
        @cat = categories(:books_classics_genre)
        @country = books_countries(:french)
        # classics: war_and_peace, clash. french: war_and_peace, got.
        RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 9)
        RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 2, score: 8)
        RankedItem.create!(item: books_books(:clash), ranking_configuration: @rc, rank: 3, score: 7)
        @cat_path = ::Books::FilterPath.call(categories: [@cat])
        @country_path = ::Books::FilterPath.call(countries: [@country])
        @pair_path = ::Books::FilterPath.call(categories: [@cat], countries: [@country])
      end

      def source(single: 1, pair: 1) = Sitemaps::Books::FilterPages.new(single_minimum: single, pair_minimum: pair)

      def paths(source) = source.entries(offset: 0, limit: 10_000).map(&:path)

      test "key is filters and lastmod is nil" do
        assert_equal "filters", source.key
        assert_nil source.lastmod
      end

      test "lists category, country and pair pages without lastmod" do
        assert_equal "/the-greatest/#{@cat.slug}/books", @cat_path
        assert_equal "/the-greatest-books/written-by/#{@country.slug}/authors", @country_path
        result = paths(source)
        assert_includes result, @cat_path
        assert_includes result, @country_path
        assert_includes result, @pair_path
        assert_equal result.size, source.count
        assert_nil source.entries(offset: 0, limit: 1).first.lastmod
      end

      test "excludes a deleted category" do
        @cat.update_columns(deleted: true)
        result = paths(source)
        refute_includes result, @cat_path
        refute_includes result, @pair_path
      end

      test "excludes the unknown country" do
        unknown = books_countries(:unknown)
        ::Books::BookCountry.create!(book: books_books(:war_and_peace), country: unknown)
        refute_includes paths(source), ::Books::FilterPath.call(countries: [unknown])
      end

      test "single threshold is inclusive" do
        n = ::Books::RankedBooksQuery.call(ranking_configuration: @rc, categories: [@cat]).count
        assert_includes paths(source(single: n)), @cat_path
        refute_includes paths(source(single: n + 1)), @cat_path
        m = ::Books::RankedBooksQuery.call(ranking_configuration: @rc, countries: [@country]).count
        assert_includes paths(source(single: m)), @country_path
        refute_includes paths(source(single: m + 1)), @country_path
      end

      test "pair threshold is inclusive" do
        n = ::Books::RankedBooksQuery.call(ranking_configuration: @rc, categories: [@cat], countries: [@country]).count
        assert_includes paths(source(pair: n)), @pair_path
        refute_includes paths(source(pair: n + 1)), @pair_path
      end

      test "orders categories, then countries, then pairs" do
        result = paths(source)
        assert result.index(@cat_path) < result.index(@country_path)
        assert result.index(@country_path) < result.index(@pair_path)
      end

      test "slices by offset and limit" do
        all = paths(source)
        assert_equal all[1, 2], source.entries(offset: 1, limit: 2).map(&:path)
      end

      test "is empty without a primary ranking configuration" do
        ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)
        assert_equal 0, source.count
        assert_empty source.entries(offset: 0, limit: 10)
      end

      test "thresholds default to Sitemaps::Thresholds" do
        Sitemaps::Thresholds.stubs(:filter_single).returns(1000)
        Sitemaps::Thresholds.stubs(:filter_pair).returns(1000)
        assert_equal 0, Sitemaps::Books::FilterPages.new.count
      end
    end
  end
end
