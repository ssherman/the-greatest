# frozen_string_literal: true

require "faraday"
require "json"

module Books
  module OpenLibrary
    # HTTP client for the Open Library data service. Modelled on
    # Music::Musicbrainz::BaseClient: Faraday + JSON in, typed
    # Exceptions::* out, every request wrapped in the CircuitBreaker.
    #
    # Unlike MusicBrainz this service speaks plain JSON (no `fmt: json` query
    # param) and never redirects, so there's no follow_redirects middleware.
    class BaseClient
      attr_reader :config, :connection, :breaker

      def initialize(config = nil, breaker: nil)
        @config = config || Configuration.new
        @breaker = breaker || CircuitBreaker.new(key: "books:open_library", failure_threshold: 5, cooldown: 60)
        @connection = build_connection
      end

      # @param path [String] e.g. "/works/OL1W"
      # @param params [Hash] query parameters
      # @param timeout [Numeric, nil] overrides config.timeout for this request only
      # @return [Hash] {success:, data:, errors:, metadata:}
      def get(path, params = {}, timeout: nil)
        perform(path) do
          connection.get(path) do |req|
            req.params = params
            req.options.timeout = timeout if timeout
          end
        end
      end

      # @param path [String] e.g. "/resolve"
      # @param body [Hash] request body, JSON-encoded
      # @param timeout [Numeric, nil] overrides config.timeout for this request only
      # @return [Hash] {success:, data:, errors:, metadata:}
      def post(path, body, timeout: nil)
        perform(path) do
          connection.post(path) do |req|
            req.headers["Content-Type"] = "application/json"
            req.body = body.to_json
            req.options.timeout = timeout if timeout
          end
        end
      end

      private

      def build_connection
        Faraday.new(url: config.base_url) do |conn|
          conn.options.timeout = config.timeout
          conn.options.open_timeout = config.open_timeout
          conn.headers["User-Agent"] = config.user_agent
          conn.headers["Accept"] = "application/json"

          conn.response :logger, config.logger, bodies: false if config.logger

          conn.adapter Faraday.default_adapter
        end
      end

      # Runs the request inside the breaker, but only lets the classes R99
      # designates as "the service is unhealthy" -- timeouts, network errors,
      # 5xx, unparseable bodies -- raise from *inside* breaker.call, since
      # that's what counts as a failure. A 404 or other 4xx is a well-formed
      # answer from a healthy service: classify_response returns it as data
      # instead of raising, so breaker.call finishes normally (and resets),
      # and only then do we raise it here, outside the counted block.
      def perform(path)
        start_time = Time.current
        outcome = nil

        breaker.call { outcome = classify_response(yield, path, start_time) }

        raise outcome[:error] if outcome[:error]
        outcome[:result]
      rescue Faraday::TimeoutError => e
        raise Exceptions::TimeoutError.new("Request timed out", e)
      rescue Faraday::ConnectionFailed => e
        raise Exceptions::NetworkError.new("Connection failed: #{e.message}", e)
      rescue Faraday::Error => e
        raise Exceptions::NetworkError.new("Network error: #{e.message}", e)
      end

      def classify_response(response, path, start_time)
        case response.status
        when 200..299
          {result: success_result(response, path, start_time)}
        when 404
          {error: Exceptions::NotFoundError.new("Not found", response.status, response.body)}
        when 400..499
          {error: Exceptions::ClientError.new("Client error: #{response.status}", response.status, response.body)}
        when 500..599
          raise Exceptions::ServerError.new("Server error: #{response.status}", response.status, response.body)
        else
          raise Exceptions::HttpError.new("Unexpected status: #{response.status}", response.status, response.body)
        end
      end

      def success_result(response, path, start_time)
        {
          success: true,
          data: parse_json(response.body),
          errors: [],
          metadata: {
            path: path,
            response_time: (Time.current - start_time).round(3),
            status_code: response.status
          }
        }
      end

      def parse_json(body)
        JSON.parse(body)
      rescue JSON::ParserError => e
        raise Exceptions::ParseError.new("Failed to parse JSON response: #{e.message}", body)
      end
    end
  end
end
