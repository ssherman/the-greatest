# frozen_string_literal: true

module PageFetcher
  # One fetched page (spec §2). `status` is the SITE's HTTP status: a 403 bot
  # wall is a successful fetch, and the caller's parser decides what it is.
  # `selector_found` is nil when no selector was asked for.
  class Page < Data.define(:url, :final_url, :status, :title, :html, :selector_found, :elapsed_ms, :fetched_at)
    # Raises KeyError for a missing field and ArgumentError for an unparseable
    # timestamp; the client turns both into Exceptions::ParseError.
    def self.from_response(body)
      new(
        url: body.fetch("url"),
        final_url: body.fetch("final_url"),
        status: body.fetch("status"),
        title: body.fetch("title"),
        html: body.fetch("html"),
        selector_found: body.fetch("selector_found"),
        elapsed_ms: body.fetch("elapsed_ms"),
        fetched_at: Time.iso8601(body.fetch("fetched_at"))
      )
    end

    # The HTML can be megabytes; it must never reach a log line through #inspect.
    def inspect
      "#<#{self.class.name} status=#{status} url=#{url.inspect} final_url=#{final_url.inspect} " \
        "title=#{title.inspect} html=(#{html.bytesize} bytes)>"
    end
    alias_method :to_s, :inspect
  end
end
