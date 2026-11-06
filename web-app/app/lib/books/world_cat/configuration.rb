# frozen_string_literal: true

module Books
  module WorldCat
    class Configuration
      DEFAULT_URL = "http://127.0.0.1:8082"
      DEFAULT_USER_AGENT = "TheGreatest/1.0 (+https://thegreatestbooks.org)"
      DEFAULT_TIMEOUT = 30
      DEFAULT_OPEN_TIMEOUT = 3
      DEFAULT_BATCH_TIMEOUT = 30

      attr_accessor :base_url, :user_agent, :timeout, :open_timeout, :batch_timeout, :logger, :access

      def initialize(base_url: nil, timeout: nil, open_timeout: nil, batch_timeout: nil, user_agent: nil, logger: nil, access: nil)
        @base_url = base_url.nil? ? ENV.fetch("WORLDCAT_SERVICE_URL", DEFAULT_URL) : base_url
        @timeout = timeout || DEFAULT_TIMEOUT
        @open_timeout = open_timeout || DEFAULT_OPEN_TIMEOUT
        @batch_timeout = batch_timeout || DEFAULT_BATCH_TIMEOUT
        @user_agent = user_agent || DEFAULT_USER_AGENT
        @logger = logger.nil? ? Rails.logger : logger
        @access = access.nil? ? CloudflareAccess::Credentials.from_env : access
        validate_configuration!
      end

      private

      def validate_configuration!
        if access.partial?
          raise Exceptions::ConfigurationError, "CLOUDFLARE_ACCESS_CLIENT_ID and CLOUDFLARE_ACCESS_CLIENT_SECRET must both be set, or neither"
        end
        raise Exceptions::ConfigurationError, "WORLDCAT_SERVICE_URL cannot be blank" if base_url.blank?
        uri = URI.parse(base_url)
        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          raise Exceptions::ConfigurationError, "WORLDCAT_SERVICE_URL must be a valid HTTP/HTTPS URL"
        end
      rescue URI::InvalidURIError
        raise Exceptions::ConfigurationError, "WORLDCAT_SERVICE_URL must be a valid URL"
      end
    end
  end
end
