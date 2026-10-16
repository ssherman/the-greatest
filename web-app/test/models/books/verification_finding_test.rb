# frozen_string_literal: true

require "test_helper"

module Books
  class VerificationFindingTest < ActiveSupport::TestCase
    setup do
      @book = books_books(:war_and_peace)
      @row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, run_id: "r")
    end

    test "kind, identifier type and sources use the identifier enums" do
      finding = VerificationFinding.create!(verification: @row, book: @book, kind: :confirmed,
        identifier_type: :books_work_isbn13, value: "9780140447934", source: :worldcat, previous_source: :legacy)

      assert finding.confirmed?
      assert finding.type_books_work_isbn13?
      assert finding.source_worldcat?
      assert finding.previous_legacy?
    end

    test "one finding per kind, type and value on a row" do
      attributes = {verification: @row, book: @book, kind: :added, identifier_type: :books_work_isbn13, value: "9780140447934"}
      VerificationFinding.create!(attributes)

      assert_raises(ActiveRecord::RecordNotUnique) { VerificationFinding.create!(attributes) }
    end
  end
end
