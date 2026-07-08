module Services
  module BooksMigration
    # Legacy users -> global User, preserving id. Bulk upsert_all bypasses the
    # after_create :create_default_user_lists callback (would create ~12 lists/user)
    # and the email presence/uniqueness validations, so email-less V1 OAuth logins
    # and the few duplicate-email rows migrate faithfully. Legacy created_at/updated_at
    # are preserved (record_timestamps? = false). The legacy OAuth identity is kept for
    # a future claiming flow: external_provider_uid, the migrated flag (legacy_migrated),
    # and the raw V1 blob (legacy_v1_data <- old_user_data). Enums copy as raw ints.
    class UserMigrator < BulkUpsertMigrator
      private

      def legacy_model
        LegacyBooks::User
      end

      def model_key
        "User"
      end

      def target_model
        User
      end

      def unique_by
        :id
      end

      def record_timestamps?
        false
      end

      def build_rows(attrs)
        [{
          id: attrs["id"],
          email: attrs["email"],
          name: attrs["name"],
          display_name: attrs["display_name"],
          photo_url: attrs["photo_url"],
          auth_uid: attrs["auth_uid"],
          auth_data: attrs["auth_data"],
          provider_data: parse_provider_data(attrs["provider_data"]),
          email_verified: attrs["email_verified"],
          external_provider: attrs["external_provider"],
          role: attrs["role"],
          sign_in_count: attrs["sign_in_count"],
          last_sign_in_at: attrs["last_sign_in_at"],
          stripe_customer_id: attrs["stripe_customer_id"],
          external_provider_uid: attrs["external_provider_uid"],
          legacy_migrated: attrs["migrated"],
          legacy_v1_data: attrs["old_user_data"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      # Legacy provider_data is a JSON string, but the new column uses
      # `serialize coder: JSON`, so upsert_all must receive the already-parsed
      # Hash (passing the raw string double-encodes it). Blank/nil -> nil; a
      # malformed JSON string raises (the base rescue names the legacy id and
      # aborts the run, which is idempotent-resumable).
      def parse_provider_data(value)
        return nil if value.blank?
        JSON.parse(value)
      end
    end
  end
end
