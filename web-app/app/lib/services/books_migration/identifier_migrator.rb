module Services
  module BooksMigration
    # Shared base for the identifier migrators. Identifiers dedupe on their natural
    # unique key (identifiable_type, identifier_type, value, identifiable_id), so
    # there is NO LegacyIdMap for identifiers themselves — upsert_identifier is a
    # find_or_create_by! on that key that skips blank values.
    class IdentifierMigrator < Migrator
      # Pure: reduce a legacy OpenLibrary path ("/works/OL20600W") to its bare
      # canonical key ("OL20600W"). The identifier_type already encodes the level,
      # so the "/works/" etc. prefix is redundant.
      def self.strip_openlibrary_key(value)
        value.to_s.rpartition("/").last.presence
      end

      private

      def upsert_identifier(identifiable_type:, identifiable_id:, identifier_type:, value:)
        return if value.blank? || identifiable_id.nil?
        Identifier.find_or_create_by!(
          identifiable_type: identifiable_type,
          identifiable_id: identifiable_id,
          identifier_type: identifier_type,
          value: value
        )
      end
    end
  end
end
