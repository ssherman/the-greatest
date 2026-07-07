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

      # ISBN-10 shape: 10 chars, first 9 digits, last a digit or X (check digit).
      # Legacy Amazon "asin" values are ISBN-10 for print books but "B0..." codes
      # for Kindle; the check keys on shape (not "starts with B") so Kindle ASINs,
      # which have letters in the first 9 positions, are preserved as ASINs.
      ISBN10_SHAPE = /\A\d{9}[\dX]\z/i

      # Pure: given a legacy "asin" value, return the work-level identifier_type
      # symbol. ISBN-10-shaped -> :books_work_isbn10, else -> :books_work_asin.
      def self.asin_identifier_type(value)
        ISBN10_SHAPE.match?(value.to_s.strip) ? :books_work_isbn10 : :books_work_asin
      end

      private

      # The identifiable target (Books::Book/Author/Edition) must already exist —
      # languages/authors/books/editions migrate before identifiers. A source id
      # with no migrated target fails Identifier's belongs_to presence validation
      # and hard-aborts the run (the per-row error names the offending legacy id;
      # the run is idempotent, so it resumes after the data is corrected).
      def upsert_identifier(identifiable_type:, identifiable_id:, identifier_type:, value:)
        value = value.to_s.strip
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
