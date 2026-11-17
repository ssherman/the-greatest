# frozen_string_literal: true

require "test_helper"

module PageFetcher
  class FileResponseTest < ActiveSupport::TestCase
    XML = "<urlset>#{"<url><loc>https://example.com/a</loc></url>" * 20}</urlset>"

    def gzip(string)
      io = StringIO.new("".b)
      gz = Zlib::GzipWriter.new(io)
      gz.mtime = 0 # the header would otherwise carry the clock, and two calls could differ
      gz.write(string)
      gz.close
      io.string
    end

    def response_hash(**overrides)
      bytes = gzip(XML)
      {
        "url" => "https://example.com/sitemap.xml.gz",
        "final_url" => "https://example.com/sitemap.xml.gz",
        "status" => 200,
        "content_type" => "application/octet-stream",
        "body_base64" => Base64.strict_encode64(bytes),
        "size_bytes" => bytes.bytesize,
        "elapsed_ms" => 4120,
        "fetched_at" => "2026-11-16T21:10:42Z"
      }.merge(overrides.transform_keys(&:to_s))
    end

    test "maps every field and decodes the body to binary" do
      response = FileResponse.from_response(response_hash)

      assert_equal "https://example.com/sitemap.xml.gz", response.url
      assert_equal "https://example.com/sitemap.xml.gz", response.final_url
      assert_equal 200, response.status
      assert_equal "application/octet-stream", response.content_type
      assert_equal gzip(XML), response.body
      assert_equal Encoding::BINARY, response.body.encoding
      assert_equal 4120, response.elapsed_ms
      assert_equal Time.utc(2026, 11, 16, 21, 10, 42), response.fetched_at
    end

    test "a null content type stays nil" do
      assert_nil FileResponse.from_response(response_hash(content_type: nil)).content_type
    end

    test "an empty body is an empty binary string" do
      response = FileResponse.from_response(response_hash(body_base64: "", size_bytes: 0))

      assert_equal "", response.body
      assert_equal Encoding::BINARY, response.body.encoding
    end

    test "a missing field raises KeyError" do
      assert_raises(KeyError) { FileResponse.from_response(response_hash.except("body_base64")) }
    end

    test "invalid base64 raises ArgumentError" do
      assert_raises(ArgumentError) { FileResponse.from_response(response_hash(body_base64: "not base64!!")) }
    end

    test "a size_bytes that disagrees with the body raises ArgumentError" do
      hash = response_hash
      assert_raises(ArgumentError) { FileResponse.from_response(hash.merge("size_bytes" => hash["size_bytes"] + 1)) }
    end

    test "an unparseable timestamp raises ArgumentError" do
      assert_raises(ArgumentError) { FileResponse.from_response(response_hash(fetched_at: "yesterday")) }
    end

    test "inflated unzips a gzip body" do
      assert_equal XML.b, FileResponse.from_response(response_hash).inflated
    end

    test "inflated returns a body that is not gzip unchanged" do
      plain = "<?xml version=\"1.0\"?><urlset/>"
      response = FileResponse.from_response(
        response_hash(body_base64: Base64.strict_encode64(plain), size_bytes: plain.bytesize)
      )

      assert_equal plain.b, response.inflated
    end

    test "inflated stops at the limit" do
      bytes = gzip("\0" * 4_096)
      response = FileResponse.from_response(
        response_hash(body_base64: Base64.strict_encode64(bytes), size_bytes: bytes.bytesize)
      )

      assert_raises(Exceptions::InflatedTooLargeError) { response.inflated(limit: 1_024) }
      assert_equal 4_096, response.inflated.bytesize
    end

    def response_for(bytes)
      FileResponse.from_response(
        response_hash(body_base64: Base64.strict_encode64(bytes), size_bytes: bytes.bytesize)
      )
    end

    test "inflated reads every member of a multi-member gzip" do
      assert_equal "firstsecond".b, response_for(gzip("first") + gzip("second")).inflated
    end

    test "the inflate limit counts across members" do
      response = response_for(gzip("\0" * 800) + gzip("\0" * 800))

      assert_raises(Exceptions::InflatedTooLargeError) { response.inflated(limit: 1_000) }
      assert_equal 1_600, response.inflated(limit: 1_600).bytesize
    end

    test "bytes after the last gzip member raise ParseError, not a silent stop" do
      error = assert_raises(Exceptions::ParseError) { response_for(gzip("first") + "garbage").inflated }
      assert_nil error.response_body
    end

    test "the gzip helper is deterministic" do
      assert_equal gzip(XML), gzip(XML)
    end

    test "a truncated gzip body raises ParseError, not a Zlib error" do
      bytes = gzip(XML).byteslice(0, gzip(XML).bytesize - 8)
      response = FileResponse.from_response(
        response_hash(body_base64: Base64.strict_encode64(bytes), size_bytes: bytes.bytesize)
      )

      error = assert_raises(Exceptions::ParseError) { response.inflated }
      assert_nil error.response_body
    end

    test "inspect, to_s and pretty_inspect never include the body" do
      plain = "SECRETBODYSECRETBODY"
      response = FileResponse.from_response(
        response_hash(body_base64: Base64.strict_encode64(plain), size_bytes: plain.bytesize)
      )

      [response.inspect, response.to_s, response.pretty_inspect].each do |text|
        assert_no_match(/SECRETBODY/, text)
        assert_no_match(/U0VDUkVU/, text)
        assert_includes text, "body=(#{plain.bytesize} bytes)"
      end
    end
  end
end
