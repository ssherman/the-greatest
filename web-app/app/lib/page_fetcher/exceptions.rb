# frozen_string_literal: true

module PageFetcher
  module Exceptions
    class Error < StandardError; end

    class ConfigurationError < Error; end

    class NetworkError < Error
      attr_reader :original_error

      def initialize(message, original_error = nil)
        super(message)
        @original_error = original_error
      end
    end

    class TimeoutError < NetworkError; end

    # A non-2xx answer from the service. `error_code` is its stable `error`
    # field (invalid_url, browser_error, ...) when the body carried one.
    class HttpError < Error
      attr_reader :status_code, :response_body, :error_code

      def initialize(message, status_code, response_body = nil, error_code: nil)
        super(message)
        @status_code = status_code
        @response_body = response_body
        @error_code = error_code
      end
    end

    # 4xx: the caller asked for something the service will not fetch. Never
    # counts against the breaker.
    class ClientError < HttpError; end

    # 5xx meaning the service is unhealthy. Counts against the breaker.
    class ServerError < HttpError; end

    # 5xx describing the site, not the service (upstream_unreachable,
    # html_too_large). Never counts against the breaker: one dead publisher
    # domain must not stop fetches to every other site.
    class UpstreamError < HttpError; end

    class ParseError < Error
      attr_reader :response_body

      def initialize(message, response_body = nil)
        super(message)
        @response_body = response_body
      end
    end

    # Raised in place of the breaker's own Books::OpenLibrary one, so that
    # `rescue PageFetcher::Exceptions::Error` catches a tripped breaker too.
    class CircuitOpenError < Error; end
  end
end
