# frozen_string_literal: true

require "faraday"
require "faraday/follow_redirects"
require "json"

module Music
  module Musicbrainz
    # Load exception classes
    require_relative "exceptions"
    class BaseClient
      attr_reader :config, :connection

      def initialize(config = nil)
        @config = config || Configuration.new
        @connection = build_connection
      end

      # Make a GET request to the MusicBrainz API
      # @param endpoint [String] the API endpoint (e.g., "artist")
      # @param params [Hash] query parameters
      # @return [Hash] parsed response with metadata
      def get(endpoint, params = {})
        start_time = Time.current

        response = connection.get(endpoint) do |req|
          req.params = build_params(params)
          req.headers["User-Agent"] = config.user_agent
        end

        parse_response(response, endpoint, params, start_time)
      rescue Faraday::TimeoutError => e
        raise TimeoutError.new("Request timed out", e)
      rescue Faraday::ConnectionFailed => e
        raise NetworkError.new("Connection failed: #{e.message}", e)
      rescue Faraday::Error => e
        raise NetworkError.new("Network error: #{e.message}", e)
      end

      private

      def build_connection
        Faraday.new(url: config.api_url) do |conn|
          conn.options.timeout = config.timeout
          conn.options.open_timeout = config.open_timeout

          # Follow redirects automatically (for MusicBrainz recording redirects)
          conn.response :follow_redirects, limit: 3

          # Add logging if logger is available
          if config.logger
            conn.response :logger, config.logger, {headers: true, bodies: false}
          end

          conn.adapter Faraday.default_adapter
        end
      end

      def build_params(params)
        # Always request JSON format
        base_params = {fmt: "json"}
        base_params.merge(params)
      end

      def parse_response(response, endpoint, params, start_time)
        response_time = Time.current - start_time

        case response.status
        when 200
          parse_success_response(response, endpoint, params, response_time)
        when 400
          raise BadRequestError.new("Bad request", response.status, response.body)
        when 404
          raise NotFoundError.new("Not found", response.status, response.body)
        when 400..499
          raise ClientError.new("Client error: #{response.status}", response.status, response.body)
        when 500..599
          raise ServerError.new("Server error: #{response.status}", response.status, response.body)
        else
          raise HttpError.new("Unexpected status: #{response.status}", response.status, response.body)
        end
      end

      def parse_success_response(response, endpoint, params, response_time)
        begin
          parsed_body = JSON.parse(response.body)
        rescue JSON::ParserError => e
          raise ParseError.new("Failed to parse JSON response: #{e.message}", response.body)
        end

        {
          success: true,
          data: parsed_body,
          errors: [],
          metadata: {
            endpoint: endpoint,
            query: params[:query],
            response_time: response_time.round(3),
            status_code: response.status
          }
        }
      end
    end
  end
end
