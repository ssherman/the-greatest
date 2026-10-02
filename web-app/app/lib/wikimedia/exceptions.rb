# frozen_string_literal: true

module Wikimedia
  module Exceptions
    class Error < StandardError; end

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

    class ParseError < Error; end

    # The Action API answered {"error": {...}} for a reason other than maxlag.
    class ApiError < Error
      attr_reader :code

      def initialize(message, code)
        super(message)
        @code = code
      end
    end

    # Not a failure: a host (a 429, a maxlag error) or our own pace asked us
    # to wait. Deliberately outside Error, so a rescue of Error never
    # swallows it; the job reschedules itself for retry_after seconds.
    class RateLimited < StandardError
      attr_reader :retry_after

      def initialize(message, retry_after:)
        super(message)
        @retry_after = retry_after
      end
    end
  end
end
