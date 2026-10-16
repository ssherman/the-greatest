# frozen_string_literal: true

require "test_helper"

module Books
  class EditionCandidateTest < ActiveSupport::TestCase
    test "one candidate per book and edition key" do
      book = books_books(:war_and_peace)
      EditionCandidate.create!(book: book, edition_key: "OL1M", identifiers: {"isbn13" => ["9780000000017"]})

      assert_raises(ActiveRecord::RecordNotUnique) { EditionCandidate.create!(book: book, edition_key: "OL1M") }
    end
  end
end
