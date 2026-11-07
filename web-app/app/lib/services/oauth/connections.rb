# frozen_string_literal: true

module Services
  module Oauth
    # The OauthConnection lifecycle: a member approving a client, and ending
    # that approval. Inside this module a bare `Oauth::` would resolve to
    # Services::Oauth, so everything outside it is root-anchored.
    class Connections
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      LAST_USED_WRITE_INTERVAL = 5.minutes

      # Records the member's approval of `application` for the resource, and
      # returns the connection. Approving again for the same (user, client,
      # resource) re-uses the row but ends everything issued under the earlier
      # approval first: a re-approval is a fresh start, so a token the member
      # forgot about does not outlive the consent that replaced it. It also
      # clears a revocation.
      #
      # A double-clicked Approve makes two requests race to insert the same
      # row; the loser hits the unique index, and one retry finds the winner's.
      #
      # An existing row is locked (SELECT ... FOR UPDATE), so two approvals of
      # one connection run one after the other. The lock only serialises them
      # if the caller issues its code inside the same transaction:
      # Oauth::AuthorizationsController#create does, so the later approval
      # always sees, and revokes, the earlier approval's code.
      def self.approve(user:, application:, resource_key:, scopes:)
        attempts = 0
        begin
          attempts += 1
          connection = ::ActiveRecord::Base.transaction(requires_new: true) do
            record = ::OauthConnection.find_or_initialize_by(
              user_id: user.id, oauth_application_id: application.id, resource: resource_key
            )
            record.lock! if record.persisted?
            now = Time.current
            revoke_children(record, now) if record.persisted?
            record.update!(scopes: scopes, approved_at: now, revoked_at: nil)
            record
          end
          success(connection)
        rescue ::ActiveRecord::RecordNotUnique
          retry if attempts < 2
          raise
        rescue ::ActiveRecord::RecordInvalid => e
          failure(*e.record.errors.full_messages)
        end
      end

      # Ends a connection: the connection itself and every token and grant
      # still live under it. Already-revoked rows, the connection included, keep
      # their original time.
      def self.revoke!(connection, at: Time.current)
        ::ActiveRecord::Base.transaction do
          revoke_children(connection, at)
          # update_columns, not update!: a connection whose resource key left the
          # registry fails validation and must still be revocable.
          connection.update_columns(revoked_at: at, updated_at: at) if connection.revoked_at.nil?
        end
        connection
      end

      # At most one write per LAST_USED_WRITE_INTERVAL, so a busy agent does not
      # cost an UPDATE per request. update_column: no validations, no callbacks,
      # no updated_at churn.
      def self.record_use(connection)
        return if connection.last_used_at.present? && connection.last_used_at > LAST_USED_WRITE_INTERVAL.ago

        connection.update_column(:last_used_at, Time.current)
      end

      def self.revoke_children(connection, at)
        connection.access_tokens.where(revoked_at: nil).update_all(revoked_at: at)
        connection.access_grants.where(revoked_at: nil).update_all(revoked_at: at)
      end
      private_class_method :revoke_children

      def self.success(data) = Result.new(success?: true, data: data, errors: [])

      def self.failure(*messages) = Result.new(success?: false, data: nil, errors: messages)
    end
  end
end
