# frozen_string_literal: true

module Books
  module OpenLibrary
    class Configuration
      # 127.0.0.1, not localhost: the service's docker-compose file publishes
      # exactly 127.0.0.1:8080, and "localhost" can resolve to ::1 first.
      DEFAULT_URL = "http://127.0.0.1:8080"
      DEFAULT_USER_AGENT = "TheGreatest/1.0 (+https://thegreatestbooks.org)"
      DEFAULT_TIMEOUT = 10
      DEFAULT_OPEN_TIMEOUT = 3
      # /resolve is measured at 5-6s on a 27-core box; give it its own budget
      # well above the retrieval-call timeout above.
      DEFAULT_RESOLVE_TIMEOUT = 60

      attr_accessor :base_url, :user_agent, :timeout, :open_timeout, :resolve_timeout, :logger

      def initialize(base_url: nil, timeout: nil, open_timeout: nil, resolve_timeout: nil, user_agent: nil, logger: nil)
        @base_url = base_url.nil? ? ENV.fetch("OPEN_LIBRARY_SERVICE_URL", DEFAULT_URL) : base_url
        @timeout = timeout.nil? ? DEFAULT_TIMEOUT : timeout
        @open_timeout = open_timeout.nil? ? DEFAULT_OPEN_TIMEOUT : open_timeout
        @resolve_timeout = resolve_timeout.nil? ? DEFAULT_RESOLVE_TIMEOUT : resolve_timeout
        @user_agent = user_agent.nil? ? DEFAULT_USER_AGENT : user_agent
        @logger = logger.nil? ? Rails.logger : logger

        validate_configuration!
      end

      private

      def validate_configuration!
        raise Exceptions::ConfigurationError, "OPEN_LIBRARY_SERVICE_URL cannot be blank" if base_url.blank?

        uri = URI.parse(base_url)
        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          raise Exceptions::ConfigurationError, "OPEN_LIBRARY_SERVICE_URL must be a valid HTTP/HTTPS URL"
        end
      rescue URI::InvalidURIError
        raise Exceptions::ConfigurationError, "OPEN_LIBRARY_SERVICE_URL must be a valid URL"
      end
    end
  end
end
