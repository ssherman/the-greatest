# frozen_string_literal: true

module Services
  module Oauth
    # Finding the OAuth access token a request presented. The one place that
    # knows what makes one usable: live, its connection live, and the connection
    # for the resource the request is aimed at (the audience binding, D3).
    # Inside this module a bare `Oauth::` would resolve to Services::Oauth, so
    # everything outside it is root-anchored.
    class AccessTokens
      # Returns the OauthAccessToken for `secret`, or nil. Nil when the request
      # maps to no resource (REST), the secret is unknown, the token is revoked
      # or expired, or its connection is revoked or belongs to another resource.
      def self.find_live(secret, resource:)
        return nil if resource.nil? || secret.blank?

        token = ::OauthAccessToken.by_token(secret)
        return nil if token.nil? || token.revoked? || token.expired?

        connection = token.connection
        return nil if connection.revoked? || connection.resource != resource.key

        token
      end

      # Called once per authenticated request. Revoking the refresh token this
      # one replaced is what makes rotation real (D11): Doorkeeper does it on
      # first use of the new access token, and nothing else would.
      def self.record_use(token)
        token.revoke_previous_refresh_token!
        Connections.record_use(token.connection)
      end
    end
  end
end
