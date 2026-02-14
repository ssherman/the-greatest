# frozen_string_literal: true

module Games
  module Igdb
    class Configuration
      DEFAULT_API_BASE_URL = "https://api.igdb.com/v4"
      DEFAULT_AUTH_URL = "https://id.twitch.tv/oauth2/token"
      DEFAULT_USER_AGENT = "The Greatest Games App/1.0"
      DEFAULT_TIMEOUT = 30
      DEFAULT_OPEN_TIMEOUT = 10
      DEFAULT_MAX_RETRIES = 3

      attr_accessor :client_id, :client_secret, :api_base_url, :auth_url,
        :timeout, :open_timeout, :logger, :user_agent, :max_retries

      def initialize
        @client_id = ENV["TWITCH_API_CLIENT_ID"]
        @client_secret = ENV["TWITCH_API_CLIENT_SECRET"]
        @api_base_url = ENV.fetch("IGDB_API_URL", DEFAULT_API_BASE_URL)
        @auth_url = ENV.fetch("TWITCH_AUTH_URL", DEFAULT_AUTH_URL)
        @timeout = DEFAULT_TIMEOUT
        @open_timeout = DEFAULT_OPEN_TIMEOUT
        @logger = Rails.logger
        @user_agent = DEFAULT_USER_AGENT
        @max_retries = DEFAULT_MAX_RETRIES

        validate_configuration!
      end

      private

      def validate_configuration!
        if client_id.blank?
          raise Exceptions::ConfigurationError, "TWITCH_API_CLIENT_ID is required"
        end

        if client_secret.blank?
          raise Exceptions::ConfigurationError, "TWITCH_API_CLIENT_SECRET is required"
        end

        validate_url!(api_base_url, "IGDB_API_URL")
        validate_url!(auth_url, "TWITCH_AUTH_URL")
      end

      def validate_url!(url, name)
        raise Exceptions::ConfigurationError, "#{name} cannot be blank" if url.blank?

        begin
          uri = URI.parse(url)
          unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
            raise Exceptions::ConfigurationError, "#{name} must be a valid HTTP/HTTPS URL"
          end
        rescue URI::InvalidURIError
          raise Exceptions::ConfigurationError, "#{name} must be a valid URL"
        end
      end
    end
  end
end
