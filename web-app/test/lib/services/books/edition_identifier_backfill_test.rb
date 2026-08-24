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
    end
  end
end
