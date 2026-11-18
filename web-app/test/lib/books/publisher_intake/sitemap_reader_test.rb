# frozen_string_literal: true

require "test_helper"

module Books
  module PublisherIntake
    class SitemapReaderTest < ActiveSupport::TestCase
      def fixture_bytes(name) = file_fixture("publisher_intake/shared/#{name}").binread

      def gzip(bytes)
        io = StringIO.new
        gz = Zlib::GzipWriter.new(io)
        gz.write(bytes)
        gz.close
        io.string
      end

      test "an index lists its three children" do
        result = SitemapReader.call(fixture_bytes("sitemap_index.xml"))

        assert_equal :index, result.kind
        assert_equal %w[https://example.test/sitemap-1.xml https://example.test/sitemap-2.xml https://example.test/sitemap-3.xml.gz],
          result.entries.map(&:loc)
      end

      test "a URL set reads lastmod as a date and as a full timestamp" do
        result = SitemapReader.call(fixture_bytes("sitemap_urlset.xml"))

        assert_equal :urlset, result.kind
        assert_equal [Date.new(2026, 11, 1), Date.new(2026, 11, 5)], result.entries.first(2).map(&:lastmod)
      end

      test "an entry with no lastmod has nil" do
        assert_nil SitemapReader.call(fixture_bytes("sitemap_urlset.xml")).entries.last.lastmod
      end

      test "gzipped bytes read the same as plain" do
        plain = fixture_bytes("sitemap_urlset.xml")

        assert_equal SitemapReader.call(plain), SitemapReader.call(gzip(plain))
      end

      test "HTML in place of XML is unreadable" do
        assert_raises(SitemapReader::Unreadable) { SitemapReader.call("<!doctype html><html><body><p>Hi</body></html>") }
      end

      test "well-formed XML with another root is unreadable" do
        assert_raises(SitemapReader::Unreadable) { SitemapReader.call("<feed><entry/></feed>") }
      end

      test "empty bytes are unreadable" do
        assert_raises(SitemapReader::Unreadable) { SitemapReader.call("") }
        assert_raises(SitemapReader::Unreadable) { SitemapReader.call(nil) }
      end

      test "corrupt gzip is unreadable" do
        assert_raises(SitemapReader::Unreadable) { SitemapReader.call("\x1F\x8B garbage".b) }
      end
    end
  end
end
