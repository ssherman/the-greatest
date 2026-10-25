# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: books_edition_candidates
#
#  id            :bigint           not null, primary key
#  edition_key   :string           not null
#  identifiers   :jsonb            not null
#  language_code :string
#  publish_year  :integer
#  subtitle      :string
#  title         :string
#  work_key      :string
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  book_id       :bigint           not null
#
# Indexes
#
#  index_books_edition_candidates_on_book_id                  (book_id)
#  index_books_edition_candidates_on_book_id_and_edition_key  (book_id,edition_key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => cascade
#
module Books
  class EditionCandidateTest < ActiveSupport::TestCase
    test "one candidate per book and edition key" do
      book = books_books(:war_and_peace)
      EditionCandidate.create!(book: book, edition_key: "OL1M", identifiers: {"isbn13" => ["9780000000017"]})

      assert_raises(ActiveRecord::RecordNotUnique) { EditionCandidate.create!(book: book, edition_key: "OL1M") }
    end
  end
end
