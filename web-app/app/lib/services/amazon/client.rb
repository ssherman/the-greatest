# frozen_string_literal: true

module Services
  module Amazon
    # Thin wrapper around the Amazon Creators API (vacuum 5.x).
    #
    # Amazon retired the Product Advertising API (PA-API 5.0) on 2026-05-15 and
    # replaced it with the Creators API: OAuth2 instead of AWS SigV4, per-request
    # marketplace and partner tag, and lowerCamelCase throughout.
    #
    # Every domain that reads Amazon product data goes through here so the
    # credentials, the marketplace and — most importantly — the response status
    # check live in exactly one place.
    class Client
      Error = Class.new(StandardError)

      # Amazon assigns a credential version at registration. 3.x means Login with
      # Amazon; 3.1 is the North America endpoint.
      CREDENTIAL_VERSION = "3.1"
      MARKETPLACE = "www.amazon.com"

      def self.search_items(**params)
        new.search_items(**params)
      end

      # Returns the raw item hashes for a search, or [] when Amazon matched
      # nothing. Raises Error on any non-2xx response — never returns [] for a
      # failed call, because callers cannot tell the two apart.
      def search_items(**params)
        response = client.search_items(
          marketplace: MARKETPLACE,
          partner_tag: partner_tag,
          **params
        )

        unless response.status.success?
          raise Error, "Amazon Creators API responded #{response.status.code}: #{response.body.to_s[0, 500]}"
        end

        response.parse.dig("searchResult", "items") || []
      end

      private

      def client
        ::Vacuum.new(
          credential_id: fetch_credential("AMAZON_PRODUCT_API_CRED_ID"),
          credential_secret: fetch_credential("AMAZON_PRODUCT_API_SECRET"),
          version: CREDENTIAL_VERSION,
          # Sidekiq runs many jobs per process; a shared store keeps the one-hour
          # access token from being re-fetched for every single job.
          cache: Rails.cache
        )
      end

      def partner_tag
        fetch_credential("AMAZON_PRODUCT_API_PARTNER_KEY")
      end

      def fetch_credential(name)
        value = ENV[name]
        raise Error, "Amazon API credentials not configured (#{name} is missing)" if value.blank?
        value
      end
    end
  end
end
