require "test_helper"

module Sitemaps
  class RegistryTest < ActiveSupport::TestCase
    test "books has no sources while public indexing is off" do
      ::Books::PublicIndexing.stubs(:enabled?).returns(false)
      assert_equal [], Sitemaps::Registry.sources(:books)
    end

    test "books has sources once public indexing is on" do
      ::Books::PublicIndexing.stubs(:enabled?).returns(true)
      assert_includes Sitemaps::Registry.sources(:books).map(&:key), "pages"
    end

    test "movies has no sources" do
      assert_equal [], Sitemaps::Registry.sources(:movies)
    end

    test "keys are unique and url-safe per domain" do
      ::Books::PublicIndexing.stubs(:enabled?).returns(true)
      %i[books music games].each do |d|
        keys = Sitemaps::Registry.sources(d).map(&:key)
        assert_not_empty keys
        assert_equal keys.uniq, keys
        keys.each { |k| assert_match(/\A[a-z_]+\z/, k) }
      end
    end

    test "find returns the source for a key" do
      assert_equal "news", Sitemaps::Registry.find(:music, "news").key
    end

    test "find returns nil for another domain's key" do
      assert_nil Sitemaps::Registry.find(:games, "songs")
    end

    test "sources are built fresh on every call" do
      assert_not_same Sitemaps::Registry.sources(:music).first, Sitemaps::Registry.sources(:music).first
    end

    test "page_size defaults to PAGE_SIZE" do
      assert_equal 50_000, Sitemaps::Registry.page_size
    end
  end
end
