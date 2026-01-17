# frozen_string_literal: true

module Cloudflare
  class Configuration
    API_BASE_URL = "https://api.cloudflare.com/client/v4"
    DEFAULT_TIMEOUT = 30
    DEFAULT_OPEN_TIMEOUT = 10

    DOMAINS = [:music, :movies, :games, :books].freeze

    attr_reader :api_token, :timeout, :open_timeout, :logger

    def initialize
      @api_token = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
      @timeout = DEFAULT_TIMEOUT
      @open_timeout = DEFAULT_OPEN_TIMEOUT
      @logger = Rails.logger

      validate_configuration!
    end

    def api_url
      API_BASE_URL
    end

    def zone_id(domain)
      domain_sym = domain.to_sym
      unless DOMAINS.include?(domain_sym)
        raise Exceptions::ZoneNotFoundError.new(domain)
      end

      ENV["#{domain_sym.upcase}_CLOUDFLARE_ZONE_ID"]
    end

    def configured_zones
      DOMAINS.each_with_object({}) do |domain, hash|
        zone_id = zone_id(domain)
        hash[domain] = zone_id if zone_id.present?
      end
    end

    private

    def validate_configuration!
      if api_token.blank?
        raise Exceptions::ConfigurationError, "CLOUDFLARE_CACHE_PURGE_TOKEN is not configured"
      end
    end
  end
end
