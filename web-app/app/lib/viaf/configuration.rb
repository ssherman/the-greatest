# frozen_string_literal: true

module Viaf
  class Configuration
    DEFAULT_URL = "https://viaf.org"
    DEFAULT_USER_AGENT = "TheGreatest/1.0 (+https://thegreatestbooks.org)"
    DEFAULT_TIMEOUT = 30
    DEFAULT_OPEN_TIMEOUT = 10

    attr_accessor :base_url, :user_agent, :timeout, :open_timeout, :logger

    def initialize
      @base_url = ENV.fetch("VIAF_URL", DEFAULT_URL)
      @user_agent = DEFAULT_USER_AGENT
      @timeout = DEFAULT_TIMEOUT
      @open_timeout = DEFAULT_OPEN_TIMEOUT
      @logger = Rails.logger

      validate_configuration!
    end

    private

    def validate_configuration!
      raise ArgumentError, "VIAF_URL cannot be blank" if base_url.blank?

      uri = URI.parse(base_url)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        raise ArgumentError, "VIAF_URL must be a valid HTTP/HTTPS URL"
      end
    rescue URI::InvalidURIError
      raise ArgumentError, "VIAF_URL must be a valid URL"
    end
  end
end
