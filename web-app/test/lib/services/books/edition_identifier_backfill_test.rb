# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class EditionIdentifierBackfillTest < ActiveSupport::TestCase
      def setup
        @edition = books_editions(:wp_legacy_amazon)
      end

      test "writes the ASIN as an edition-level identifier" do
        EditionIdentifierBackfill.call

        assert_equal ["1400042062"],
          @edition.identifiers.where(identifier_type: :books_edition_asin).pluck(:value)
      end

      test "classifies a 10-character ISBN as isbn10" do
        EditionIdentifierBackfill.call

        assert_equal ["1400042062"],
          @edition.identifiers.where(identifier_type: :books_edition_isbn10).pluck(:value)
        assert_empty @edition.identifiers.where(identifier_type: :books_edition_isbn13)
      end

      test "writes the EAN as ean13" do
        EditionIdentifierBackfill.call

        assert_equal ["9781400042067"],
          @edition.identifiers.where(identifier_type: :books_edition_ean13).pluck(:value)
      end

      test "is idempotent across repeated runs" do
        EditionIdentifierBackfill.call
        count_after_first = @edition.identifiers.count

        EditionIdentifierBackfill.call

        assert_equal count_after_first, @edition.identifiers.count
      end

      test "ignores editions with no amazon metadata" do
        plain = books_editions(:wp_maude)

        EditionIdentifierBackfill.call

        assert_empty plain.identifiers.where(identifier_type: :books_edition_asin)
      end

      test "returns the number of rows written" do
        written = EditionIdentifierBackfill.call

        assert_operator written, :>=, 3
      end

      # This is the query the books:amazon_enrich* rake tasks use to verify the
      # backfill actually covers every edition before enrichment runs -- an
      # edition carrying the legacy PascalCase blob but no books_edition_asin
      # identifier is exactly the "would get duplicated" case.
      test "an edition with legacy Amazon metadata and no ASIN identifier is detectable as un-backfilled" do
        uncovered = -> {
          ::Books::Edition.where("books_editions.metadata -> 'amazon' ->> 'ASIN' IS NOT NULL")
            .where.not(
              id: ::Identifier.where(identifiable_type: "Books::Edition", identifier_type: :books_edition_asin)
                .select(:identifiable_id)
            )
        }

        # wp_legacy_amazon carries the PascalCase blob and starts with no identifiers.
        assert_includes uncovered.call.pluck(:id), @edition.id

        EditionIdentifierBackfill.call

        refute_includes uncovered.call.pluck(:id), @edition.id
      end
    end
  end
end
