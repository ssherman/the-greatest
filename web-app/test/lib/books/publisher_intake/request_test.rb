# frozen_string_literal: true

require "test_helper"

module Books
  module PublisherIntake
    class RequestTest < ActiveSupport::TestCase
      test "page builds a page request with its selector and context" do
        request = Request.page("https://example.test/a", wait_for_selector: "h1", context: {"n" => 2})

        assert_equal ["page", "https://example.test/a", nil, "h1", {"n" => 2}],
          [request.kind, request.url, request.page_url, request.wait_for_selector, request.context]
      end

      test "file builds a file request with its page url" do
        request = Request.file("https://example.test/a.xml", page_url: "https://example.test/")

        assert_equal ["file", "https://example.test/a.xml", "https://example.test/", nil, {}],
          [request.kind, request.url, request.page_url, request.wait_for_selector, request.context]
      end

      test "to_h has string keys" do
        assert_equal %w[context kind page_url url wait_for_selector], Request.page("https://example.test/a").to_h.keys.sort
      end

      test "from_h of to_h round-trips" do
        request = Request.file("https://example.test/a.xml", page_url: "https://example.test/", context: {"kind" => "child"})

        assert_equal request, Request.from_h(request.to_h)
      end

      test "from_h of a JSON round trip equals the original" do
        request = Request.page("https://example.test/a", wait_for_selector: ".x", context: {"page" => 3, "tags" => ["a"]})

        assert_equal request, Request.from_h(JSON.parse(request.to_h.to_json))
      end
    end
  end
end
