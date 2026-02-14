# frozen_string_literal: true

require "faraday"
require "json"

module Games
  module Igdb
    class BaseClient
      attr_reader :config, :authentication, :rate_limiter

      def initialize(config = nil)
        @config = config || Configuration.new
        @authentication = Authentication.new(@config)
        @rate_limiter = RateLimiter.new
        @connection = build_connection
      end

      def post(endpoint, query_string)
        start_time = Time.current

        ensure_authenticated!
        rate_limiter.wait!

        response = @connection.post(endpoint) do |req|
          req.headers["Client-ID"] = config.client_id
          req.headers["Authorization"] = "Bearer #{authentication.access_token}"
          req.headers["User-Agent"] = config.user_agent
          req.headers["Content-Type"] = "text/plain"
          req.body = query_string
        end

        parse_response(response, endpoint, query_string, start_time)
      rescue Faraday::TimeoutError => e
        raise Exceptions::TimeoutError.new("Request timed out", e)
      rescue Faraday::ConnectionFailed => e
        raise Exceptions::NetworkError.new("Connection failed: #{e.message}", e)
      rescue Faraday::Error => e
        raise Exceptions::NetworkError.new("Network error: #{e.message}", e)
      end

      private

      def build_connection
        Faraday.new(url: config.api_base_url) do |conn|
          conn.options.timeout = config.timeout
          conn.options.open_timeout = config.open_timeout
          conn.adapter Faraday.default_adapter
        end
      end

      def ensure_authenticated!
        authentication.access_token
      rescue Exceptions::AuthenticationError
        raise
      end

      def parse_response(response, endpoint, query_string, start_time)
        response_time = Time.current - start_time

        case response.status
        when 200
          parse_success_response(response, endpoint, query_string, response_time)
        when 400
          raise Exceptions::BadRequestError.new("Bad request", response.status, response.body)
        when 401
          handle_unauthorized(endpoint, query_string, start_time)
        when 404
          raise Exceptions::NotFoundError.new("Not found", response.status, response.body)
        when 429
          handle_rate_limit(endpoint, query_string, start_time)
        when 400..499
          raise Exceptions::ClientError.new("Client error: #{response.status}", response.status, response.body)
        when 500..599
          raise Exceptions::ServerError.new("Server error: #{response.status}", response.status, response.body)
        else
          raise Exceptions::HttpError.new("Unexpected status: #{response.status}", response.status, response.body)
        end
      end

      def parse_success_response(response, endpoint, query_string, response_time)
        begin
          parsed_body = JSON.parse(response.body)
        rescue JSON::ParserError => e
          raise Exceptions::ParseError.new("Failed to parse JSON response: #{e.message}", response.body)
        end

        {
          success: true,
          data: parsed_body,
          errors: [],
          metadata: {
            endpoint: endpoint,
            query: query_string,
            response_time: response_time.round(3),
            status_code: response.status
          }
        }
      end

      def handle_unauthorized(endpoint, query_string, start_time)
        # Force token refresh and retry once
        authentication.refresh_token!

        response = @connection.post(endpoint) do |req|
          req.headers["Client-ID"] = config.client_id
          req.headers["Authorization"] = "Bearer #{authentication.access_token}"
          req.headers["User-Agent"] = config.user_agent
          req.headers["Content-Type"] = "text/plain"
          req.body = query_string
        end

        if response.status == 401
          raise Exceptions::UnauthorizedError.new("Unauthorized after token refresh", 401, response.body)
        end

        parse_response(response, endpoint, query_string, start_time)
      end

      def handle_rate_limit(endpoint, query_string, start_time)
        config.max_retries.times do |attempt|
          sleep_time = 2**attempt # exponential backoff: 1, 2, 4
          sleep(sleep_time)

          response = @connection.post(endpoint) do |req|
            req.headers["Client-ID"] = config.client_id
            req.headers["Authorization"] = "Bearer #{authentication.access_token}"
            req.headers["User-Agent"] = config.user_agent
            req.headers["Content-Type"] = "text/plain"
            req.body = query_string
          end

          unless response.status == 429
            return parse_response(response, endpoint, query_string, start_time)
          end
        end

        raise Exceptions::RateLimitError.new("Rate limit exceeded after #{config.max_retries} retries", 429)
      end
    end
  end
end
