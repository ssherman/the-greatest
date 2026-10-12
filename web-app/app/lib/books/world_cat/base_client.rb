# frozen_string_literal: true

require "faraday"
require "json"

module Books
  module WorldCat
    # HTTP client for the WorldCat lookup service. A copy of
    # Books::OpenLibrary::BaseClient, deliberately not a subclass of it: a
    # subclass would raise Open Library's exception classes, and callers rescue
    # by source. Faraday + JSON in, typed Exceptions::* out, every request
    # wrapped in the (source-agnostic) Books::OpenLibrary::CircuitBreaker.
    #
    # The service speaks plain JSON and never redirects. It has no busy reply,
    # so a 503 is an ordinary ServerError.
    #
    # The two log filters below exist because the service sits behind
    # Cloudflare Access: the service-token secret is sent as a request header,
    # and Access answers with a signed CF_Authorization cookie. Neither may
    # reach a log line.
    class BaseClient
      attr_reader :config, :connection, :breaker

      def initialize(config = nil, breaker: nil)
        @config = config || Configuration.new
        @breaker = breaker || Books::OpenLibrary::CircuitBreaker.new(key: "books:world_cat", failure_threshold: 5, cooldown: 60)
        @connection = build_connection
      end

      # @param path [String] e.g. "/isbns/9780735211292"
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

      # @param path [String] e.g. "/lookup"
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
          config.access.headers.each { |name, value| conn.headers[name] = value }

          if config.logger
            conn.response :logger, config.logger, bodies: false do |logger|
              # Faraday logs request headers as `Name: "value"`.
              logger.filter(/(CF-Access-Client-Secret: )"[^"]*"/, '\1"[FILTERED]"')
              # Access answers with a signed CF_Authorization cookie that admits
              # its bearer to the app for a day, without the service token.
              logger.filter(/(CF_Authorization=)[^;"]+/, '\1[FILTERED]')
            end
          end

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
      rescue Books::OpenLibrary::Exceptions::CircuitOpenError => e
        # The breaker is shared with Open Library and raises that namespace's
        # error; callers of this client rescue ours.
        raise Exceptions::CircuitOpenError, e.message
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
