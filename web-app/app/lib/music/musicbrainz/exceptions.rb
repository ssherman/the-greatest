# frozen_string_literal: true

module Music
  module Musicbrainz
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

      class ClientError < HttpError; end      # 4xx errors

      class ServerError < HttpError; end      # 5xx errors

      class NotFoundError < ClientError; end  # 404 errors

      class BadRequestError < ClientError; end # 400 errors

      class ParseError < Error
        attr_reader :response_body

        def initialize(message, response_body = nil)
          super(message)
          @response_body = response_body
        end
      end

      class QueryError < Error; end # Invalid Lucene queries
    end
  end
end
