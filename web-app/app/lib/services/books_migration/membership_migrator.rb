module Services
  module BooksMigration
    # Legacy `users.paid = true` -> a global Membership with source: :legacy.
    #
    # These 28 early supporters have no Stripe representation at all, which is
    # why the account-wide reconcile cannot produce them: they are the half of
    # the migration that can only come from the legacy database.
    #
    # Legacy `paid` is a PERMANENT grant, not a denormalised subscription flag.
    # Verified in the legacy source: User#member? is `paid? || active_membership?`
    # and webhooks_controller.rb stopped writing the column years ago. So a user
    # who is both an early supporter and a paying subscriber legitimately ends up
    # with two membership rows, and keeps access if the Stripe one lapses --
    # exactly what the live legacy site does today.
    #
    # current_period_end stays nil on purpose: Membership.granting_access is
    # designed to read a non-Stripe row as "active AND (current_period_end IS
    # NULL OR in the future)", so nil is what will encode "never expires" --
    # but that method ships with the entitlements increment and does not exist
    # yet. Nothing in the app currently reads memberships to grant or deny
    # access; see "Known limits" in docs/features/membership-billing.md.
    #
    # Timestamps are NOT copied from the legacy user. users.created_at is the
    # signup date, not the date the grant was made; there is no column recording
    # the latter, so these rows get today's.
    #
    # Re-running converges every row onto the legacy `paid` flag -- it is NOT
    # idempotent in the sense of "safe to re-run without consequence". If an
    # admin has revoked a legacy grant in /admin/memberships (status:
    # :canceled), and the legacy `paid` flag is still true, the next run flips
    # that row back to :active and clears canceled_at. This is intentional:
    # the importer mirrors the legacy database, and that database is where a
    # revoke is meant to stick. The remedy for a revoke that must survive a
    # re-run is to clear `paid` on the legacy user, not to edit the row here.
    class MembershipMigrator < Migrator
      NOTE = "Legacy early supporter"

      private

      # Scoped so the run streams 28 rows rather than every legacy user. The
      # `paid` check is repeated in upsert_row below because every migrator test
      # stubs legacy_each, which makes a scope-level filter untestable -- the
      # same tradeoff ReviewMigrator documents for its dedup.
      def legacy_model
        LegacyBooks::User.where(paid: true)
      end

      def model_key
        "Membership"
      end

      def upsert_row(attrs)
        return unless attrs["paid"]
        # A legacy user created after the user migration ran has no row here.
        # Skip rather than raise: the same books/users drift that makes
        # data_migration:reviews fail standalone against the live legacy
        # database. billing:verify_migration reports the shortfall by id.
        return unless ::User.exists?(id: attrs["id"])

        membership = ::Membership.find_or_initialize_by(user_id: attrs["id"], source: :legacy)
        membership.status = :active
        membership.current_period_end = nil
        # Cleared alongside status: without this, re-running after an admin
        # revoke (which sets canceled_at) produced an active row that still
        # claimed to have been cancelled. See the class comment.
        membership.canceled_at = nil
        # ||= so a note an admin has edited survives a re-run.
        membership.note ||= NOTE
        membership.save!
      end
    end
  end
end
