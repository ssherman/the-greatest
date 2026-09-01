# frozen_string_literal: true

module Viaf
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

    class ClientError < HttpError; end

    class ServerError < HttpError; end

    class NotFoundError < ClientError; end

    class BadRequestError < ClientError; end

    # Cloudflare refused to forward the request. This is NOT VIAF rejecting it.
    # Roughly 5-8 rapid requests trips a WAF rule that blocks the IP for minutes.
    # Never retry: evidence suggests retrying refreshes the ban.
    class BlockedError < HttpError; end

    class ParseError < Error
      attr_reader :response_body

      def initialize(message, response_body = nil)
        super(message)
        @response_body = response_body
      end
    end

    # The cluster exists but VIAF has withdrawn it (abandoned / scavenged / redirect).
    class AbandonedRecordError < Error; end
  end
end
