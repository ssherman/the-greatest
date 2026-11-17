# frozen_string_literal: true

require "base64"
require "zlib"

module PageFetcher
  # One fetched file: the bytes exactly as the site sent them (a .gz arrives
  # still gzipped), decoded from the service's base64. `status` is the SITE's
  # HTTP status, as on Page. `content_type` is nil when the site sent none.
  # The body is never logged, never put on an exception message, never stored.
  class FileResponse < Data.define(:url, :final_url, :status, :content_type, :body, :elapsed_ms, :fetched_at)
    # Output cap for #inflated. A gzip bomb is a few KB in and gigabytes out.
    MAX_INFLATED_BYTES = 100 * 1024 * 1024

    GZIP_MAGIC = "\x1F\x8B".b
    CHUNK_BYTES = 64 * 1024

    # Raises KeyError for a missing field and ArgumentError for a wrong type,
    # invalid base64, a size_bytes that is not body.bytesize, or a bad
    # timestamp; the client turns all of these into Exceptions::ParseError.
    def self.from_response(body)
      encoded = body.fetch("body_base64")
      unless encoded.is_a?(String)
        raise ArgumentError, "PageFetcher::FileResponse#from_response: body_base64 must be a String, got #{encoded.class}"
      end

      fetched_at = body.fetch("fetched_at")
      unless fetched_at.is_a?(String)
        raise ArgumentError, "PageFetcher::FileResponse#from_response: fetched_at must be a String, got #{fetched_at.class}"
      end

      bytes = Base64.strict_decode64(encoded).b
      size_bytes = body.fetch("size_bytes")
      unless size_bytes == bytes.bytesize
        raise ArgumentError, "PageFetcher::FileResponse#from_response: size_bytes #{size_bytes.inspect} does not match the decoded body (#{bytes.bytesize} bytes)"
      end

      new(
        url: body.fetch("url"),
        final_url: body.fetch("final_url"),
        status: body.fetch("status"),
        content_type: body.fetch("content_type"),
        body: bytes,
        elapsed_ms: body.fetch("elapsed_ms"),
        fetched_at: Time.iso8601(fetched_at)
      )
    end

    # The body unzipped when it starts with the gzip magic bytes, the body
    # itself otherwise. Reads in chunks and stops at `limit` bytes of output,
    # so a gzip bomb never inflates in full.
    def inflated(limit: MAX_INFLATED_BYTES)
      return body unless body.start_with?(GZIP_MAGIC)

      out = "".b
      reader = Zlib::GzipReader.new(StringIO.new(body))
      begin
        while (chunk = reader.read(CHUNK_BYTES))
          out << chunk
          if out.bytesize > limit
            raise Exceptions::InflatedTooLargeError, "gzip body inflates past #{limit} bytes"
          end
        end
      ensure
        reader.close
      end
      out
    rescue Zlib::Error => e
      # Deliberately no response body: the message is Zlib's alone.
      raise Exceptions::ParseError, "PageFetcher::FileResponse#inflated: corrupt gzip body (#{e.class})"
    end

    # The body can be megabytes; it must never reach a log line through #inspect.
    def inspect
      "#<#{self.class.name} status=#{status} url=#{url.inspect} final_url=#{final_url.inspect} " \
        "content_type=#{content_type.inspect} body=(#{body.bytesize} bytes)>"
    end
    alias_method :to_s, :inspect

    # pp.rb's Data#pretty_print lists every member and ignores a custom
    # #inspect; without this override `pp` would print the whole body.
    def pretty_print(q) = q.text(inspect)
  end
end
