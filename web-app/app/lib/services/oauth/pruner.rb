# frozen_string_literal: true

module Services
  module Oauth
    # Daily cleanup of the OAuth tables. It deletes only rows no check can
    # reach any more. Doorkeeper's own stale-record cleaner is deliberately not
    # used: it deletes revoked tokens, and a revoked refresh token that is
    # still newer than its connection's approval is what reuse detection (D11)
    # recognises. Connections are never deleted.
    #
    # - applications: older than the unused-client lifetime with no connection
    #   row at all (a connection is created on Approve, before any grant).
    # - grants: older than the retention, far above the 10-minute code life.
    # - tokens: every token of a revoked connection, and tokens older than a
    #   live connection's approved_at (stale from before a re-approval).
    #   Revoked tokens newer than approved_at and live unrevoked tokens stay.
    class Pruner
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      BATCH = 1_000

      def self.call(now: Time.current) = new(now).call

      def initialize(now)
        @now = now
      end

      def call
        config = Rails.application.config.x.api
        data = {
          applications: prune_applications(config.oauth_unused_client_lifetime),
          grants: prune_grants(config.oauth_grant_retention),
          tokens: prune_tokens
        }
        Result.new(success?: true, data: data, errors: [])
      end

      private

      def prune_applications(lifetime)
        scope = ::OauthApplication
          .where(created_at: ...(@now - lifetime))
          .where.not(id: ::OauthConnection.select(:oauth_application_id))
        delete(scope)
      end

      def prune_grants(retention)
        delete(::OauthAccessGrant.where(created_at: ...(@now - retention)))
      end

      def prune_tokens
        revoked = ::OauthAccessToken.where(connection_id: ::OauthConnection.where.not(revoked_at: nil).select(:id))
        stale = ::OauthAccessToken.joins(:connection)
          .where(oauth_connections: {revoked_at: nil})
          .where("oauth_access_tokens.created_at < oauth_connections.approved_at")
        delete(revoked) + delete(stale)
      end

      def delete(scope)
        total = 0
        scope.in_batches(of: BATCH) { |batch| total += batch.delete_all }
        total
      end
    end
  end
end
