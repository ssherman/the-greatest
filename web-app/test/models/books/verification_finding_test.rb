# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: books_verification_findings
#
#  id              :bigint           not null, primary key
#  evidence        :jsonb            not null
#  identifier_type :integer          not null
#  kind            :integer          not null
#  previous_source :integer
#  source          :integer
#  undo_action     :integer
#  undone_at       :datetime
#  value           :string           not null
#  work_key        :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  book_id         :bigint           not null
#  identifier_id   :bigint
#  other_book_id   :bigint
#  verification_id :bigint           not null
#
# Indexes
#
#  index_books_verification_findings_on_book_id          (book_id)
#  index_books_verification_findings_on_kind             (kind)
#  index_books_verification_findings_on_other_book_id    (other_book_id)
#  index_books_verification_findings_on_verification_id  (verification_id)
#  index_books_verification_findings_unique              (verification_id,kind,identifier_type,value) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => cascade
#  fk_rails_...  (other_book_id => books_books.id) ON DELETE => cascade
#  fk_rails_...  (verification_id => books_verifications.id) ON DELETE => cascade
#
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
