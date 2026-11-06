require "test_helper"

module Services
  module Books
    module GoodreadsEnrichment
      class LedgerTest < ActiveSupport::TestCase
        test "writes a books.goodreads row for the outcome and reason" do
          book = books_books(:war_and_peace)

          row = Ledger.record(book: book, outcome: :unrecognized, reason: :no_match, facts: {"rows" => 3})

          assert_equal ["books.goodreads", "goodreads", "unrecognized", "no_match", {"rows" => 3}],
            [row.kind, row.provider, row.outcome, row.reason, row.facts]
          assert_equal book, row.enrichable
        end

        test "keeps the error of a failed attempt" do
          row = Ledger.record(book: books_books(:war_and_peace), outcome: :failed, error: "timeout")

          assert_equal ["failed", "timeout"], [row.outcome, row.error]
        end
      end
    end
  end
end
