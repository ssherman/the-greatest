# frozen_string_literal: true

require "faraday"
require "json"

module Viaf
  # HTTP transport for VIAF.
  #
  # VIAF dropped format suffixes in the January 2025 rebuild, so the content
  # type is negotiated with an Accept header rather than a .json path suffix.
  class BaseClient
    BLOCKED_MARKER = "you have been blocked"

    # Merged clusters answer 301 pointing at the surviving cluster, so
    # redirects are a normal occurrence, not an edge case. Redirects are
    # handled here rather than via Faraday's `follow_redirects` middleware
    # because that middleware resolves every hop *inside* the connection,
    # bypassing `@rate_limiter.wait!` for every hop after the first. Against
    # a Cloudflare WAF that blocks on ~5-8 rapid requests, that amplification
    # (1 limiter slot for up to 4 upstream requests) is enough on its own to
    # trip the ban. Looping through the public `#get` path instead means
    # every hop pays for its own slot.
    REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze
    MAX_REDIRECTS = 3

    attr_reader :config, :connection, :last_rate_limit

    def initialize(config = nil, rate_limiter: nil)
      @config = config || Configuration.new
      @rate_limiter = rate_limiter || RateLimiter.new
      @connection = build_connection
      @last_rate_limit = nil
    end

    def get(path, params = {})
      start_time = Time.current
      response = fetch_with_redirects(path, params)
      parse_response(response, path, start_time)
    rescue Faraday::TimeoutError => e
      raise Exceptions::TimeoutError.new("Request timed out", e)
    rescue Faraday::ConnectionFailed => e
      raise Exceptions::NetworkError.new("Connection failed: #{e.message}", e)
    rescue Faraday::Error => e
      raise Exceptions::NetworkError.new("Network error: #{e.message}", e)
    end

    private

    # Performs the request, then follows any 301/302/303/307/308 by
    # recursing into itself with the redirected URL. Each recursive call
    # goes through the same `@rate_limiter.wait!` this method starts with,
    # so an N-hop redirect chain acquires N+1 limiter slots — one per
    # upstream request, matching the connection's actual request count.
    def fetch_with_redirects(url, params, redirect_count: 0)
      @rate_limiter.wait!

      response = connection.get(url) do |req|
        req.params.update(params)
        req.headers["Accept"] = "application/json"
        req.headers["User-Agent"] = config.user_agent
      end

      return response unless REDIRECT_STATUSES.include?(response.status)

      if redirect_count >= MAX_REDIRECTS
        raise Exceptions::NetworkError.new(
          "Exceeded maximum redirects (#{MAX_REDIRECTS}) resolving #{url}"
        )
      end

      location = response.headers["location"]
      if location.blank?
        raise Exceptions::NetworkError.new(
          "Redirect response (#{response.status}) is missing a Location header"
        )
      end

      # Params belong to the original request only: the Location header is
      # already a complete (or resolvable) URL, so re-applying the caller's
      # params to it would risk duplicating or overriding its query string.
      fetch_with_redirects(resolve_redirect_url(response, location), {}, redirect_count: redirect_count + 1)
    end

    # Resolves Location per RFC 3986: relative to the URL that was just
    # requested (not the configured base_url), same as a browser or
    # Faraday's own follow_redirects middleware would. VIAF sends absolute
    # URLs today, but this keeps a relative one from crashing or silently
    # requesting the wrong host.
    def resolve_redirect_url(response, location)
      response.env.url.merge(location).to_s
    rescue URI::Error => e
      raise Exceptions::NetworkError.new("Invalid redirect Location header #{location.inspect}: #{e.message}", e)
    end

    def build_connection
      Faraday.new(url: config.base_url) do |conn|
        conn.options.timeout = config.timeout
        conn.options.open_timeout = config.open_timeout
        conn.adapter Faraday.default_adapter
      end
    end

    def parse_response(response, path, start_time)
      response_time = Time.current - start_time
      @last_rate_limit = extract_rate_limit(response)

      case response.status
      when 200
        parse_success(response, path, response_time)
      when 403
        raise Exceptions::BlockedError.new(blocked_message(response), 403, response.body)
      when 400
        raise Exceptions::BadRequestError.new("Bad request", 400, response.body)
      when 404
        raise Exceptions::NotFoundError.new("Not found", 404, response.body)
      when 400..499
        raise Exceptions::ClientError.new("Client error: #{response.status}", response.status, response.body)
      when 500..599
        raise Exceptions::ServerError.new("Server error: #{response.status}", response.status, response.body)
      else
        raise Exceptions::HttpError.new("Unexpected status: #{response.status}", response.status, response.body)
      end
    end

    def blocked_message(response)
      if blocked_body?(response)
        "Cloudflare blocked this request. Do not retry; back off."
      else
        "Forbidden (403). Treating as blocked; do not retry."
      end
    end

    def blocked_body?(response)
      response.body.to_s.downcase.include?(BLOCKED_MARKER)
    end

    def parse_success(response, path, response_time)
      # Cloudflare can also serve its interstitial with a 200 status (e.g. a
      # managed challenge page). Check for the marker before attempting to
      # parse JSON so this raises BlockedError, never ParseError.
      if blocked_body?(response)
        raise Exceptions::BlockedError.new(blocked_message(response), response.status, response.body)
      end

      parsed = begin
        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise Exceptions::ParseError.new("Failed to parse JSON response: #{e.message}", response.body)
      end

      {
        success: true,
        data: parsed,
        errors: [],
        metadata: {
          path: path,
          response_time: response_time.round(3),
          status_code: response.status,
          rate_limit: @last_rate_limit
        }
      }
    end

    def extract_rate_limit(response)
      headers = response.respond_to?(:headers) ? response.headers : {}
      {
        limit: headers["ratelimit-limit"]&.to_i,
        remaining: headers["ratelimit-remaining"]&.to_i,
        remaining_day: headers["x-ratelimit-remaining-day"]&.to_i
      }
    end
  end
end
