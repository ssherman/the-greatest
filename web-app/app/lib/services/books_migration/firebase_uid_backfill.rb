module Services
  module BooksMigration
    # Writes the imported Firebase uid onto users.auth_uid so PR 1's uid-primary
    # lookup matches a v1 user on their first sign-in without any email being
    # involved.
    #
    # It recomputes the uid rather than reading the export file: the value is
    # derived from the id, so the two cannot drift, this is safe to run in any
    # environment, and it needs nothing shipped between machines.
    #
    # This is only correct because UserMigrator upserts unique_by: :id, making
    # LegacyBooks::User#id and User#id the same integer for the same person. A
    # cohort id with no new-table row means that migration did not fully run, so
    # the whole backfill aborts rather than skipping the row -- a skipped row is
    # a user who silently cannot sign in.
    #
    # Run it AFTER the Firebase import in each cycle, so auth_uid never points
    # at an identity that does not exist yet. It is re-run after every
    # production data migration, because truncating and re-migrating resets
    # auth_uid for the whole cohort.
    class FirebaseUidBackfill
      BATCH_SIZE = 1000

      def self.call(dry_run: false)
        new(dry_run: dry_run).call
      end

      def initialize(dry_run: false)
        @dry_run = dry_run
      end

      def call
        ids = cohort_ids
        return empty_result if ids.empty?

        present_ids = User.where(id: ids).pluck(:id)
        missing = ids - present_ids
        if missing.any?
          return {
            success: false,
            error: "#{missing.size} cohort ids have no row in users (first: #{missing.first(5).join(", ")}). " \
                   "Run data_migration:users first.",
            data: {eligible: 0, updated: 0, already_set: 0, missing_target: missing}
          }
        end

        eligible = eligible_ids(ids)
        already_set = ids.size - eligible.size

        return dry_result(eligible.size, already_set) if @dry_run

        # No transaction wrapping the slices on purpose. A partial run is
        # harmless -- every slice is scoped to auth_uid IS NULL and the uid is
        # derived, so re-running finishes the job rather than double-applying.
        # Holding one transaction over 30k rows would buy nothing and lock the
        # table for the duration, on a database music and games are live on.
        updated = 0
        eligible.each_slice(BATCH_SIZE) do |slice|
          updated += update_slice(slice)
        end

        {success: true, data: {eligible: eligible.size, updated: updated, already_set: already_set, missing_target: []}}
      rescue => e
        {success: false, error: e.message, data: {eligible: 0, updated: 0, already_set: 0, missing_target: []}}
      end

      private

      # A seam as much as a query: it is what the race test replaces to hand
      # `call` a stale eligibility list, which is the only way to exercise the
      # auth_uid IS NULL scope on the UPDATE below.
      def eligible_ids(ids)
        User.where(id: ids, auth_uid: nil).pluck(:id)
      end

      # One statement per batch, deriving the uid in SQL so 30k rows do not become
      # 30k UPDATEs.
      #
      # The auth_uid IS NULL scope is NOT redundant with eligible_ids, even
      # though every id reaching here came from it. It closes the window
      # between that read and this write: a cohort member who signs in during
      # the run gets a Firebase-native uid, and without this scope the backfill
      # would overwrite it with tgbv1-<id> and detach them from the account
      # they just authenticated to. Removing it passes every other test in the
      # file -- see "does not clobber a uid set between the eligibility check
      # and the write", which exists precisely because that mutation was
      # otherwise silent.
      #
      # This is a second implementation of the shape FirebasePasswordExport.uid_for
      # owns in Ruby. It shares UID_PREFIX, but the concatenation is duplicated,
      # so the backfill test asserts equality with uid_for across a spread of ids
      # -- that assertion is the only thing keeping the exported localId and the
      # stored auth_uid from drifting apart.
      def update_slice(ids)
        User.where(id: ids, auth_uid: nil).update_all([
          "auth_uid = ? || id::text, updated_at = ?",
          Services::BooksMigration::FirebasePasswordExport::UID_PREFIX,
          Time.current
        ])
      end

      # Identical to FirebasePasswordExport#cohort's filter, deliberately: the
      # set exported to Firebase and the set given a uid here have to be the
      # same people, or a user gets an account they cannot be matched to.
      def cohort_ids
        LegacyBooks::User
          .where(migrated: [false, nil])
          .where(external_provider: nil)
          .where("old_encrypted_password IS NOT NULL AND old_encrypted_password <> ''")
          .where("email IS NOT NULL AND email <> ''")
          .pluck(:id)
      end

      def empty_result
        {success: true, data: {eligible: 0, updated: 0, already_set: 0, missing_target: []}}
      end

      def dry_result(eligible, already_set)
        {success: true, data: {eligible: eligible, updated: 0, already_set: already_set, missing_target: []}}
      end
    end
  end
end
