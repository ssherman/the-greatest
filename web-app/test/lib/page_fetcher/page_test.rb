# frozen_string_literal: true

require "test_helper"

module PageFetcher
  class PageTest < ActiveSupport::TestCase
    BODY = {
      "url" => "https://www.goodreads.com/book/show/4671",
      "final_url" => "https://www.goodreads.com/book/show/4671.The_Great_Gatsby",
      "status" => 403,
      "title" => "Just a moment...",
      "html" => "<html>#{"x" * 5000}</html>",
      "selector_found" => nil,
      "elapsed_ms" => 4120,
      "fetched_at" => "2026-09-26T18:02:11Z"
    }.freeze

    test "maps every field of a fetch response" do
      page = PageFetcher::Page.from_response(BODY)

      assert_equal BODY["url"], page.url
      assert_equal BODY["final_url"], page.final_url
      assert_equal 403, page.status
      assert_equal "Just a moment...", page.title
      assert_equal BODY["html"], page.html
      assert_nil page.selector_found
      assert_equal 4120, page.elapsed_ms
      assert_equal Time.utc(2026, 9, 26, 18, 2, 11), page.fetched_at
    end

    test "a missing field raises KeyError" do
      assert_raises(KeyError) { PageFetcher::Page.from_response(BODY.except("html")) }
    end

    test "an unparseable timestamp raises ArgumentError" do
      assert_raises(ArgumentError) { PageFetcher::Page.from_response(BODY.merge("fetched_at" => "yesterday")) }
    end

    test "a non-string fetched_at raises ArgumentError" do
      assert_raises(ArgumentError) { PageFetcher::Page.from_response(BODY.merge("fetched_at" => 1758909731)) }
    end

    test "a null html raises ArgumentError" do
      assert_raises(ArgumentError) { PageFetcher::Page.from_response(BODY.merge("html" => nil)) }
    end

    test "inspect, to_s and pretty_inspect never include the html" do
      page = PageFetcher::Page.from_response(BODY)

      [page.inspect, page.to_s, page.pretty_inspect].each do |text|
        assert_no_match(/xxxxx/, text)
        assert_includes text, "bytes"
        assert_includes text, "403"
      end
    end
  end
end
