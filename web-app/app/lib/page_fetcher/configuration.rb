# frozen_string_literal: true

module PageFetcher
  class Configuration
    # 127.0.0.1, not localhost: data-sources' compose file publishes exactly
    # 127.0.0.1:8081, and "localhost" can resolve to ::1 first.
    DEFAULT_URL = "http://127.0.0.1:8081"
    DEFAULT_USER_AGENT = "TheGreatest/1.0 (+https://thegreatestbooks.org)"
    DEFAULT_OPEN_TIMEOUT = 3

    attr_accessor :base_url, :open_timeout, :user_agent, :logger

    def initialize(base_url: nil, open_timeout: nil, user_agent: nil, logger: nil)
      @base_url = base_url.nil? ? ENV.fetch("PAGE_FETCHER_SERVICE_URL", DEFAULT_URL) : base_url
      @open_timeout = open_timeout.nil? ? DEFAULT_OPEN_TIMEOUT : open_timeout
      @user_agent = user_agent.nil? ? DEFAULT_USER_AGENT : user_agent
      @logger = logger.nil? ? Rails.logger : logger

      validate_configuration!
    end

    private

    def validate_configuration!
      raise Exceptions::ConfigurationError, "PAGE_FETCHER_SERVICE_URL cannot be blank" if base_url.blank?

      uri = URI.parse(base_url)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        raise Exceptions::ConfigurationError, "PAGE_FETCHER_SERVICE_URL must be a valid HTTP/HTTPS URL"
      end
    rescue URI::InvalidURIError
      raise Exceptions::ConfigurationError, "PAGE_FETCHER_SERVICE_URL must be a valid URL"
    end
  end
end
