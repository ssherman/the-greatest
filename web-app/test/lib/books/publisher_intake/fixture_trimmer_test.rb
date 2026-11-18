# frozen_string_literal: true

require "test_helper"

module Books
  module PublisherIntake
    class FixtureTrimmerTest < ActiveSupport::TestCase
      LONG = "#{"A very long sentence that goes on and on. " * 10}Another."

      def trimmed(body)
        Nokogiri::HTML(FixtureTrimmer.call("<html><head><title>T</title></head><body>#{body}</body></html>"))
      end

      test "scripts other than JSON-LD, styles, svg, noscript, iframes and comments are removed" do
        doc = trimmed(<<~HTML)
          <script>alert(1)</script><script type="application/ld+json">{"name":"X"}</script>
          <style>p{}</style><svg><path/></svg><noscript>no</noscript><iframe src="x"></iframe><!-- gone --><p>kept</p>
        HTML

        assert_equal ["application/ld+json"], doc.css("script").map { |s| s["type"] }
        assert_empty doc.css("style, svg, noscript, iframe")
        refute_includes doc.to_html, "gone"
        assert_equal "kept", doc.at("p").text
      end

      test "srcset attributes are removed from img and source" do
        doc = trimmed('<img src="a.jpg" srcset="a.jpg 1x, b.jpg 2x"><picture><source srcset="c.jpg 1x"></picture>')

        assert_equal "a.jpg", doc.at("img")["src"]
        assert_nil doc.at("img")["srcset"]
        assert_nil doc.at("source")["srcset"]
      end

      test "a text node over 200 characters is cut to its first sentence" do
        assert_equal "A very long sentence that goes on and on.", trimmed("<p>#{LONG}</p>").at("p").text
      end

      test "short text is left alone and a long text without a full stop is cut at 200 characters" do
        assert_equal "Short. Text.", trimmed("<p>Short. Text.</p>").at("p").text
        assert_operator trimmed("<p>#{"x" * 500}</p>").at("p").text.length, :<=, 201
      end

      test "long strings inside JSON-LD are cut too" do
        doc = trimmed(%(<script type="application/ld+json">#{JSON.generate({"description" => LONG, "name" => "N"})}</script>))

        assert_equal({"description" => "A very long sentence that goes on and on.", "name" => "N"}, JSON.parse(doc.at("script").text))
      end
    end
  end
end
