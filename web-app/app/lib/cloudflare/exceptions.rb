# frozen_string_literal: true

module Cloudflare
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

    class HttpError < Error
      attr_reader :status_code, :response_body

      def initialize(message, status_code, response_body = nil)
        super(message)
        @status_code = status_code
        @response_body = response_body
      end
    end

    class AuthenticationError < HttpError; end  # 401/403 errors

    class RateLimitError < HttpError; end       # 429 errors

    class ServerError < HttpError; end          # 5xx errors

    class ZoneNotFoundError < Error
      attr_reader :domain

      def initialize(domain)
        super("Zone ID not configured for domain: #{domain}")
        @domain = domain
      end
    end
  end
end
