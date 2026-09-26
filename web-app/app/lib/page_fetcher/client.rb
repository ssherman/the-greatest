# frozen_string_literal: true

require "faraday"
require "json"

module PageFetcher
  # HTTP client for the page fetcher service in data-sources/ (spec:
  # docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md, §5).
  # One endpoint, so one class holds the HTTP, the breaker and the error
  # mapping. Nothing here knows a browser exists.
  class Client
    # Service error codes that describe the site, not the service (spec §2).
    UPSTREAM_ERROR_CODES = %w[upstream_unreachable html_too_large].freeze
    # The service answers within the fetch budget plus its 5 s browser-close
    # limit; the rest is margin, so Rails never abandons a fetch in progress.
    READ_TIMEOUT_PADDING = 10

    attr_reader :config, :breaker, :connection

    def initialize(config: nil, breaker: nil)
      @config = config || Configuration.new
      # Books::OpenLibrary::CircuitBreaker is generic (Redis-backed, keyed);
      # moving it to a shared namespace is a spec §12 carry-forward.
      @breaker = breaker || Books::OpenLibrary::CircuitBreaker.new(key: "page_fetcher", failure_threshold: 5, cooldown: 60)
      @connection = build_connection
    end

    # @return [PageFetcher::Page]
    # @raise [PageFetcher::Exceptions::Error] or a subclass, and nothing else
    def fetch(url, wait_until: "load", wait_for_selector: nil, timeout_ms: 30_000)
      body = {url: url, wait_until: wait_until, timeout_ms: timeout_ms}
      body[:wait_for_selector] = wait_for_selector if wait_for_selector.present?
      read_timeout = timeout_ms / 1000.0 + READ_TIMEOUT_PADDING

      outcome = nil
      breaker.call { outcome = classify(post(body, read_timeout)) }
      raise outcome[:error] if outcome[:error]

      outcome[:page]
    rescue Books::OpenLibrary::Exceptions::CircuitOpenError => e
      raise Exceptions::CircuitOpenError, e.message
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
        conn.options.open_timeout = config.open_timeout
        conn.headers["User-Agent"] = config.user_agent
        conn.headers["Accept"] = "application/json"
        # bodies: false -- a response body is a whole page of HTML (spec §6).
        conn.response :logger, config.logger, bodies: false if config.logger
        conn.adapter Faraday.default_adapter
      end
    end

    def post(body, read_timeout)
      connection.post("/fetch") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = body.to_json
        req.options.timeout = read_timeout
      end
    end

    # Runs inside breaker.call. Raises what means "the service is unhealthy"
    # (a 5xx other than an upstream code, an unparseable body); returns
    # everything else, so a caller bug (4xx) or a dead site (UpstreamError)
    # finishes the block normally and never trips the breaker.
    def classify(response)
      case response.status
      when 200..299
        {page: parse_page(response.body)}
      when 400..499
        {error: http_error(Exceptions::ClientError, response)}
      when 500..599
        code, = error_fields(response.body)
        return {error: http_error(Exceptions::UpstreamError, response)} if UPSTREAM_ERROR_CODES.include?(code)

        raise http_error(Exceptions::ServerError, response)
      else
        raise Exceptions::HttpError.new("Unexpected status: #{response.status}", response.status, response.body)
      end
    end

    def http_error(error_class, response)
      code, detail = error_fields(response.body)
      message = [code, detail].compact.join(": ").presence || "HTTP #{response.status}"
      error_class.new(message, response.status, response.body, error_code: code)
    end

    # The service's {"error": code, "detail": text} body (spec §2), or
    # [nil, nil] for anything else; FastAPI's 422 body has no "error" key.
    def error_fields(body)
      parsed = JSON.parse(body.to_s)
      return [nil, nil] unless parsed.is_a?(Hash)

      [parsed["error"], (parsed["detail"] if parsed["detail"].is_a?(String))]
    rescue JSON::ParserError
      [nil, nil]
    end

    # response_body is always nil here: a 200 body is the fetch response,
    # which carries the page's HTML, and keeping it on the exception would
    # let an error tracker store it (spec §6 -- HTML is never logged, cached
    # or stored). A JSON::ParserError's own message is not used either: it
    # quotes the unparseable input.
    def parse_page(body)
      parsed = JSON.parse(body)
      raise Exceptions::ParseError.new("The fetch response is not a JSON object", nil) unless parsed.is_a?(Hash)

      Page.from_response(parsed)
    rescue JSON::ParserError
      raise Exceptions::ParseError.new("The fetch response is not JSON", nil)
    rescue KeyError, ArgumentError => e
      raise Exceptions::ParseError.new("Failed to parse the fetch response: #{e.message}", nil)
    end
  end
end
