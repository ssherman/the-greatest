# frozen_string_literal: true

require "faraday"
require "faraday/follow_redirects"
require "json"

module Viaf
  # HTTP transport for VIAF.
  #
  # VIAF dropped format suffixes in the January 2025 rebuild, so the content
  # type is negotiated with an Accept header rather than a .json path suffix.
  class BaseClient
    BLOCKED_MARKER = "you have been blocked"

    attr_reader :config, :connection, :last_rate_limit

    def initialize(config = nil, rate_limiter: nil)
      @config = config || Configuration.new
      @rate_limiter = rate_limiter || RateLimiter.new
      @connection = build_connection
      @last_rate_limit = nil
    end

    def get(path, params = {})
      start_time = Time.current
      @rate_limiter.wait!

      response = connection.get(path) do |req|
        req.params = params
        req.headers["Accept"] = "application/json"
        req.headers["User-Agent"] = config.user_agent
      end

      parse_response(response, path, start_time)
    rescue Faraday::TimeoutError => e
      raise Exceptions::TimeoutError.new("Request timed out", e)
    rescue Faraday::ConnectionFailed => e
      raise Exceptions::NetworkError.new("Connection failed: #{e.message}", e)
    rescue Faraday::Error => e
      raise Exceptions::NetworkError.new("Network error: #{e.message}", e)
    end

    private

    def build_connection
      Faraday.new(url: config.base_url) do |conn|
        conn.options.timeout = config.timeout
        conn.options.open_timeout = config.open_timeout
        # Merged clusters answer 301 pointing at the surviving cluster.
        conn.response :follow_redirects, limit: 3
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
      if response.body.to_s.downcase.include?(BLOCKED_MARKER)
        "Cloudflare blocked this request. Do not retry; back off."
      else
        "Forbidden (403). Treating as blocked; do not retry."
      end
    end

    def parse_success(response, path, response_time)
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
