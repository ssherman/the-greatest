# frozen_string_literal: true

require "zlib"
require "stringio"

module Books
  module PublisherIntake
    # Reads a sitemap index or URL set, gzipped or plain. Namespaces are
    # dropped first: real sitemaps declare a default one.
    module SitemapReader
      class Unreadable < StandardError; end

      Entry = Data.define(:loc, :lastmod)
      Result = Data.define(:kind, :entries)

      GZIP_MAGIC = "\x1F\x8B".b

      def self.call(bytes)
        xml = inflate(bytes.to_s.b)
        raise Unreadable, "empty" if xml.strip.empty?

        doc = Nokogiri::XML(xml, &:strict)
        doc.remove_namespaces!
        case doc.root&.name
        when "sitemapindex" then Result.new(kind: :index, entries: entries(doc, "sitemap"))
        when "urlset" then Result.new(kind: :urlset, entries: entries(doc, "url"))
        else raise Unreadable, "not a sitemap"
        end
      rescue Nokogiri::XML::SyntaxError
        raise Unreadable, "not XML"
      end

      def self.inflate(bytes)
        return bytes unless bytes.start_with?(GZIP_MAGIC)

        Zlib::GzipReader.new(StringIO.new(bytes)).read
      rescue Zlib::Error
        raise Unreadable, "bad gzip"
      end

      def self.entries(doc, element)
        doc.xpath("//#{element}").filter_map do |node|
          loc = node.at_xpath("loc")&.text.to_s.strip
          next if loc.empty?

          Entry.new(loc: loc, lastmod: parse_date(node.at_xpath("lastmod")&.text))
        end
      end

      def self.parse_date(text)
        text.present? ? Date.parse(text) : nil
      rescue Date::Error
        nil
      end

      private_class_method :inflate, :entries, :parse_date
    end
  end
end
