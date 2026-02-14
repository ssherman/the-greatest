# frozen_string_literal: true

require "faraday"
require "json"

module Games
  module Igdb
    class Authentication
      TOKEN_REFRESH_BUFFER = 300 # 5 minutes before expiry

      attr_reader :config

      def initialize(config)
        @config = config
        @access_token = nil
        @token_expires_at = nil
        @mutex = Mutex.new
      end

      def access_token
        @mutex.synchronize do
          perform_refresh! if token_expired?
          @access_token
        end
      end

      def token_expired?
        @access_token.nil? || @token_expires_at.nil? ||
          Time.current >= (@token_expires_at - TOKEN_REFRESH_BUFFER)
      end

      def refresh_token!
        @mutex.synchronize do
          perform_refresh!
        end
      end

      private

      def perform_refresh!
        response = request_token

        unless response.status == 200
          raise Exceptions::AuthenticationError,
            "Twitch OAuth failed (#{response.status}): #{response.body}"
        end

        data = JSON.parse(response.body)
        @access_token = data["access_token"]
        @token_expires_at = Time.current + data["expires_in"].to_i
      rescue JSON::ParserError => e
        raise Exceptions::AuthenticationError,
          "Failed to parse auth response: #{e.message}"
      rescue Faraday::Error => e
        raise Exceptions::AuthenticationError,
          "Auth request failed: #{e.message}"
      end

      def request_token
        connection = Faraday.new(url: config.auth_url) do |conn|
          conn.options.timeout = config.timeout
          conn.options.open_timeout = config.open_timeout
          conn.adapter Faraday.default_adapter
        end

        connection.post("") do |req|
          req.params = {
            client_id: config.client_id,
            client_secret: config.client_secret,
            grant_type: "client_credentials"
          }
        end
      end
    end
  end
end
