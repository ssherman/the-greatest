# frozen_string_literal: true

require "faraday"
require "json"

module Cloudflare
  class BaseClient
    attr_reader :config, :connection

    def initialize(config = nil)
      @config = config || Configuration.new
      @connection = build_connection
    end

    def post(endpoint, body:)
      start_time = Time.current

      response = connection.post(endpoint) do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = body.to_json
      end

      parse_response(response, endpoint, start_time)
    rescue Faraday::TimeoutError => e
      raise Exceptions::TimeoutError.new("Request timed out", e)
    rescue Faraday::ConnectionFailed => e
      raise Exceptions::NetworkError.new("Connection failed: #{e.message}", e)
    rescue Faraday::Error => e
      raise Exceptions::NetworkError.new("Network error: #{e.message}", e)
    end

    private

    def build_connection
      Faraday.new(url: config.api_url) do |conn|
        conn.options.timeout = config.timeout
        conn.options.open_timeout = config.open_timeout

        conn.request :authorization, "Bearer", config.api_token

        if config.logger && Rails.env.development?
          conn.response :logger, config.logger, {headers: true, bodies: false}
        end

        conn.adapter Faraday.default_adapter
      end
    end

    def parse_response(response, endpoint, start_time)
      response_time = Time.current - start_time

      case response.status
      when 200..299
        parse_success_response(response, endpoint, response_time)
      when 401, 403
        raise Exceptions::AuthenticationError.new(
          "Authentication failed",
          response.status,
          response.body
        )
      when 429
        raise Exceptions::RateLimitError.new(
          "Rate limit exceeded. Try again later.",
          response.status,
          response.body
        )
      when 500..599
        raise Exceptions::ServerError.new(
          "Cloudflare server error: #{response.status}",
          response.status,
          response.body
        )
      else
        raise Exceptions::HttpError.new(
          "Unexpected status: #{response.status}",
          response.status,
          response.body
        )
      end
    end

    def parse_success_response(response, endpoint, response_time)
      parsed_body = JSON.parse(response.body)

      unless parsed_body["success"]
        errors = parsed_body["errors"]&.map { |e| e["message"] }&.join(", ")
        raise Exceptions::HttpError.new(
          "API error: #{errors}",
          response.status,
          response.body
        )
      end

      {
        success: true,
        result: parsed_body["result"],
        metadata: {
          endpoint: endpoint,
          response_time: response_time.round(3),
          status_code: response.status
        }
      }
    rescue JSON::ParserError => e
      raise Exceptions::NetworkError.new("Failed to parse JSON response: #{e.message}")
    end
  end
end
