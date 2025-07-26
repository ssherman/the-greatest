# frozen_string_literal: true

module Music
  module Musicbrainz
    class Configuration
      DEFAULT_URL = "https://musicbrainz.org"
      DEFAULT_USER_AGENT = "The Greatest Music App/1.0"
      DEFAULT_TIMEOUT = 30
      DEFAULT_OPEN_TIMEOUT = 10

      attr_accessor :base_url, :user_agent, :timeout, :open_timeout, :logger

      def initialize
        @base_url = ENV.fetch("MUSICBRAINZ_URL", DEFAULT_URL)
        @user_agent = DEFAULT_USER_AGENT
        @timeout = DEFAULT_TIMEOUT
        @open_timeout = DEFAULT_OPEN_TIMEOUT
        @logger = Rails.logger
        
        validate_configuration!
      end

      def api_url
        "#{base_url}/ws/2"
      end

      private

      def validate_configuration!
        raise ArgumentError, "MUSICBRAINZ_URL cannot be blank" if base_url.blank?
        
        begin
          uri = URI.parse(base_url)
          unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
            raise ArgumentError, "MUSICBRAINZ_URL must be a valid HTTP/HTTPS URL"
          end
        rescue URI::InvalidURIError
          raise ArgumentError, "MUSICBRAINZ_URL must be a valid URL"
        end
      end
    end
  end
end 