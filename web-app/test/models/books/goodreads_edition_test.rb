require "test_helper"

# == Schema Information
#
# Table name: books_goodreads_editions
#
#  id                        :bigint           not null, primary key
#  additional_authors        :string           default([]), not null, is an Array
#  book_format               :string
#  isbn10                    :string
#  isbn13                    :string
#  original_publication_year :integer
#  pages                     :integer
#  primary_author            :string           not null
#  publisher                 :string
#  resolution                :integer
#  resolved_at               :datetime
#  series_name               :string
#  series_number             :string
#  signature                 :string           not null
#  title                     :string           not null
#  verification              :integer          default("not_needed"), not null
#  year_published            :integer
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  book_id                   :bigint
#  goodreads_book_id         :bigint           not null
#  match_decision_id         :bigint
#  pending_import_id         :bigint
#
# Indexes
#
#  idx_on_goodreads_book_id_signature_8e389d2d73        (goodreads_book_id,signature) UNIQUE
#  index_books_goodreads_editions_on_book_id            (book_id)
#  index_books_goodreads_editions_on_match_decision_id  (match_decision_id)
#  index_books_goodreads_editions_on_pending_import_id  (pending_import_id)
#  index_books_goodreads_editions_on_signature          (signature)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => nullify
#  fk_rails_...  (match_decision_id => match_decisions.id) ON DELETE => nullify
#  fk_rails_...  (pending_import_id => books_goodreads_imports.id) ON DELETE => nullify
#
module Books
  class GoodreadsEditionTest < ActiveSupport::TestCase
    test "a Goodreads id may carry a second signature but never the same one twice" do
      honest = books_goodreads_editions(:war_and_peace_edition)
      hostile = GoodreadsEdition.new(goodreads_book_id: honest.goodreads_book_id,
        signature: Goodreads::ExportRow.signature("Invented Book", "Nobody"), title: "Invented Book", primary_author: "Nobody")
      duplicate = GoodreadsEdition.new(goodreads_book_id: honest.goodreads_book_id, signature: honest.signature,
        title: honest.title, primary_author: honest.primary_author)

      assert hostile.valid?
      assert_not duplicate.valid?
    end

    test "the fixture signatures are what ExportRow computes" do
      edition = books_goodreads_editions(:unresolved_edition)

      assert_equal Goodreads::ExportRow.signature(edition.title, edition.primary_author), edition.signature
    end

    test "deleting its book unlinks the edition" do
      book = Book.create!(title: "Ephemeral")
      edition = books_goodreads_editions(:unresolved_edition)
      edition.update!(book: book, resolution: :created, resolved_at: Time.current)

      book.destroy!

      assert_nil edition.reload.book_id
    end

    test "awaiting_goodreads: editions waiting for their page, and those created before it could be read" do
      waiting = GoodreadsEdition.create!(goodreads_book_id: 1, signature: "a", title: "A", primary_author: "X", verification: :pending)
      unverified = GoodreadsEdition.create!(goodreads_book_id: 2, signature: "b", title: "B", primary_author: "X",
        resolution: :created, verification: :unverified, book: books_books(:war_and_peace), resolved_at: Time.current)
      GoodreadsEdition.create!(goodreads_book_id: 3, signature: "c", title: "C", primary_author: "X",
        resolution: :created, verification: :verified, book: books_books(:war_and_peace), resolved_at: Time.current)
      GoodreadsEdition.create!(goodreads_book_id: 4, signature: "d", title: "D", primary_author: "X",
        resolution: :matched, verification: :not_needed, book: books_books(:war_and_peace), resolved_at: Time.current)

      assert_equal [waiting, unverified].sort_by(&:id), GoodreadsEdition.awaiting_goodreads.order(:id).to_a
    end
  end
end
