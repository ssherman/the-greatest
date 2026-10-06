# frozen_string_literal: true

module Books
  module OpenLibrary
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

      # The service's 503 busy: it is already running as many /resolve calls
      # as it allows and turned this one away at once. The service is up, so
      # the breaker ignores it. `retry_after` is the service's Retry-After in
      # seconds, nil when absent or unparseable.
      class BusyError < ServerError
        attr_reader :retry_after

        def initialize(message, status_code, response_body = nil, retry_after: nil)
          super(message, status_code, response_body)
          @retry_after = retry_after
        end
      end

      class NotFoundError < ClientError; end

      class ParseError < Error
        attr_reader :response_body

        def initialize(message, response_body = nil)
          super(message)
          @response_body = response_body
        end
      end

      # Raised by CircuitBreaker#call when the circuit is open; the block is
      # never invoked.
      class CircuitOpenError < Error; end
    end
  end
end
