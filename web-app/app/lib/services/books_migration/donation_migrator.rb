module Services
  module BooksMigration
    # Legacy `donations` -> the global donations table.
    #
    # The other half of the migration that can only come from the legacy
    # database. Donation history is append-only and was never touched by the
    # ordering bugs in the legacy webhook handler, so it is the one legacy
    # billing table that is trustworthy as written.
    #
    # Column renames: stripe_payment_id -> stripe_payment_intent_id, amount ->
    # amount_cents. Legacy `amount` is ALREADY in cents (legacy's
    # amount_in_dollars divides by 100); the rename exists so no call site has
    # to remember that.
    #
    # The legacy status enum is pending: 0, succeeded: 1, failed: 2, refunded: 3
    # -- identical to the new one -- so the raw integer copies directly. Legacy
    # has no currency column; the new column's "usd" default applies.
    #
    # Legacy timestamps ARE preserved: a donation's created_at is the date the
    # money arrived, which is the fact being imported.
    class DonationMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Donation
      end

      def model_key
        "Donation"
      end

      def upsert_row(attrs)
        payment_intent_id = attrs["stripe_payment_id"].presence
        # The unique index on stripe_payment_intent_id is PARTIAL (WHERE NOT
        # NULL), so a nil is unconstrained and find_or_initialize_by(nil) would
        # match some unrelated nil-id row and silently overwrite it. Legacy
        # validates this column's presence and all 21 production rows carry a
        # pi_ id, so a blank here means the data is not what we believe. The
        # base class turns this into an aborted run naming the legacy id.
        raise "legacy donation has no stripe_payment_id" if payment_intent_id.nil?

        donation = ::Donation.find_or_initialize_by(stripe_payment_intent_id: payment_intent_id)
        # Append-only history: an existing row is either a previous import or a
        # webhook-recorded donation, and both are better than anything this
        # migrator would write over them.
        return if donation.persisted?

        donation.assign_attributes(
          # A donor whose account no longer exists imports unattached rather
          # than failing the run -- the same books/users drift MembershipMigrator
          # skips for.
          user_id: (attrs["user_id"] if ::User.exists?(id: attrs["user_id"])),
          amount_cents: attrs["amount"],
          status: attrs["status"],
          domain: "books",
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        )
        donation.save!
      end
    end
  end
end
