# frozen_string_literal: true

module Services
  module Oauth
    # The checks the token endpoint makes before Doorkeeper sees a request
    # (P-d). Doorkeeper knows a refresh token is revoked or unknown; it does not
    # know that a revoked one coming back means it leaked, that the member's
    # membership has lapsed, or that the client named a resource the approval
    # was not for. Refusing here means no row is created and there is nothing to
    # clean up. Inside this module a bare `Oauth::` would resolve to
    # Services::Oauth, so everything outside it is root-anchored.
    #
    # `errors` holds `:invalid_grant` or `:invalid_target`. A refresh token this
    # cannot find passes through: Doorkeeper answers it with the same
    # `invalid_grant`, so a probe cannot tell "unknown" from "revoked" by the
    # reply.
    class TokenGate
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(params:, domain:) = new(params, domain).call

      def initialize(params, domain)
        @params = params
        @domain = domain
      end

      def call
        case @params[:grant_type]
        when "refresh_token" then check_refresh
        when "authorization_code" then check_code
        else allow
        end
      end

      private

      def check_refresh
        secret = @params[:refresh_token]
        return allow unless secret.is_a?(String) && secret.present?

        token = ::OauthAccessToken.by_refresh_token(secret)
        return allow if token.nil?

        connection = token.connection
        if token.revoked?
          # A refresh token is revoked when the access token that replaced it is
          # first used, so seeing one again means two parties hold it (D11). A
          # token revoked by an earlier approval is older than this approval and
          # is only stale: it must not end the approval that replaced it (P-e).
          Connections.revoke!(connection) if token.created_at >= connection.approved_at
          return refuse(:invalid_grant)
        end

        return refuse(:invalid_grant) if connection.revoked?

        # Renewing the membership later does not bring this connection back:
        # the member approves again.
        if ::Api::Scopes.effective(connection.scopes, connection.user).empty?
          Connections.revoke!(connection)
          return refuse(:invalid_grant)
        end

        check_resource(connection)
      end

      def check_code
        code = @params[:code]
        return allow unless code.is_a?(String) && code.present?

        grant = ::OauthAccessGrant.by_token(code)
        return allow if grant.nil?

        check_resource(grant.connection)
      end

      # RFC 8707: a client that names a resource must name the one this approval
      # is for. Absent is fine; the approval already fixed it.
      def check_resource(connection)
        requested = @params[:resource]
        return allow if requested.nil? || requested == ""
        return refuse(:invalid_target) unless requested.is_a?(String)

        resource = ::Oauth::Resources.for_url(requested, ::Api::Host.base_url(@domain))
        return refuse(:invalid_target) unless resource&.key == connection.resource

        allow
      end

      def allow = Result.new(success?: true, data: nil, errors: [])

      def refuse(code) = Result.new(success?: false, data: nil, errors: [code])
    end
  end
end
