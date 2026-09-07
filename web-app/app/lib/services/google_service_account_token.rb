# frozen_string_literal: true

require "base64"
require "faraday"
require "json"
require "jwt"
require "monitor"
require "openssl"

module Services
  # Mints and caches the OAuth bearer token used to call Identity Toolkit as
  # this project's service account.
  #
  # In-process rather than Rails.cache for the same reason
  # JwtValidationService caches certs in-process: production configures no
  # cache_store, so Rails.cache is a per-container file store anyway.
  class GoogleServiceAccountToken
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    SCOPE = "https://www.googleapis.com/auth/identitytoolkit"
    GRANT_TYPE = "urn:ietf:params:oauth:grant-type:jwt-bearer"
    ASSERTION_LIFETIME = 3600
    # Refresh this far before expiry so a token never expires mid-request.
    REFRESH_BUFFER = 300
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 3

    class Error < StandardError; end

    LOCK = Monitor.new

    class << self
      def access_token
        LOCK.synchronize do
          refresh! if expired?
          @access_token
        end
      end

      def reset!
        LOCK.synchronize do
          @access_token = nil
          @expires_at = nil
        end
      end

      private

      def expired?
        @access_token.nil? || @expires_at.nil? ||
          Time.current >= (@expires_at - REFRESH_BUFFER)
      end

      def refresh!
        response = post_assertion(build_assertion)

        unless response.status == 200
          raise Error, "token exchange failed (#{response.status})"
        end

        data = JSON.parse(response.body)
        token = data["access_token"]
        raise Error, "token exchange returned no access_token" if token.blank?

        @access_token = token
        @expires_at = Time.current + data["expires_in"].to_i
      rescue JSON::ParserError => e
        raise Error, "token exchange returned an unparseable body: #{e.message}"
      rescue Faraday::Error => e
        raise Error, "token exchange request failed: #{e.class}"
      end

      def credentials
        raw = ENV["FIREBASE_SERVICE_ACCOUNT_KEY"]
        raise Error, "FIREBASE_SERVICE_ACCOUNT_KEY is not set" if raw.blank?

        JSON.parse(Base64.decode64(raw))
      rescue JSON::ParserError
        raise Error, "FIREBASE_SERVICE_ACCOUNT_KEY is not valid base64-encoded JSON"
      end

      def build_assertion
        creds = credentials
        now = Time.current.to_i

        JWT.encode(
          {
            iss: creds.fetch("client_email"),
            scope: SCOPE,
            aud: TOKEN_URL,
            iat: now,
            exp: now + ASSERTION_LIFETIME
          },
          OpenSSL::PKey::RSA.new(creds.fetch("private_key")),
          "RS256"
        )
      rescue KeyError => e
        raise Error, "service account key is missing #{e.key}"
      rescue OpenSSL::PKey::RSAError
        raise Error, "service account private_key is not a usable RSA key"
      end

      def post_assertion(assertion)
        connection = Faraday.new(url: TOKEN_URL) do |conn|
          conn.options.open_timeout = OPEN_TIMEOUT
          conn.options.timeout = READ_TIMEOUT
          conn.adapter Faraday.default_adapter
        end

        connection.post("") do |req|
          req.headers["Content-Type"] = "application/x-www-form-urlencoded"
          req.body = URI.encode_www_form(grant_type: GRANT_TYPE, assertion: assertion)
        end
      end
    end
  end
end
