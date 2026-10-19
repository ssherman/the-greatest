# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class SignalsTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace) # fixture isbn13 9780140447934, unmarked
          @row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, new_key: "OL1W", run_id: "r", stage: :signals)
        end

        def hold(type, value) = Identifier.create!(identifiable: @book, identifier_type: type, value: value, source: :legacy)

        def run_signals(hits:, works:)
          Signals.call(verification: @row, client: FakeOlClient.new(hits: hits, works: works))
          @row.reload
        end

        test "identifiers pointing at two other works with other titles make a lump suspect" do
          hold(:books_work_goodreads_id, "1")
          row = run_signals(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL7W")], ["goodreads", "1"] => [ol_hit("OL8W", id_type: "goodreads", value: "1")]},
            works: {"OL7W" => ol_work("OL7W", title: "Anna Karenina"), "OL8W" => ol_work("OL8W", title: "Resurrection")}
          )

          assert row.lump_suspect
          assert_equal %w[OL7W OL8W], row.findings.foreign_work.order(:work_key).pluck(:work_key)
          assert_equal [{"key" => "OL7W", "title" => "Anna Karenina"}], row.findings.find_by!(work_key: "OL7W").evidence["works"]
          assert row.stage_done?
          assert_not_nil row.checked_at
        end

        test "values that are not a valid ISBN or Goodreads id are never looked up and use no lookup slot" do
          hold(:books_work_isbn13, "Twelfth Night")
          hold(:books_work_isbn10, "12345")
          hold(:books_work_goodreads_id, "gr-77")
          client = FakeOlClient.new
          Signals.call(verification: @row, client: client)

          assert_equal [[:identifier, "isbn13", "9780140447934"]], client.calls.select { |call| call.first == :identifier }
          assert @row.reload.stage_done?
        end

        test "a slug-form Goodreads id is still looked up" do
          hold(:books_work_goodreads_id, "32076670-ball-lightning")
          client = FakeOlClient.new
          Signals.call(verification: @row, client: client)

          assert_includes client.calls, [:identifier, "goodreads", "32076670-ball-lightning"]
        end

        test "one foreign work is recorded but is not a lump" do
          row = run_signals(hits: {["isbn13", "9780140447934"] => [ol_hit("OL7W")]}, works: {"OL7W" => ol_work("OL7W", title: "Anna Karenina")})

          assert_equal 1, row.findings.foreign_work.count
          refute row.lump_suspect
        end

        test "the settled work, its duplicates and its redirects are not foreign" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL2W", source: :open_library)
          hold(:books_work_goodreads_id, "1")
          hold(:books_work_goodreads_id, "2")
          redirected = ::Books::OpenLibrary::IdentifierHit.new(work_key: "OL3W", source: "openlibrary", redirected_from: ["OL1W"],
            edition_keys: [], id_type: "goodreads", value: "2")
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")], ["goodreads", "1"] => [ol_hit("OL2W", id_type: "goodreads", value: "1")],
                   ["goodreads", "2"] => [redirected]},
            works: %w[OL1W OL2W OL3W].to_h { |key| [key, ol_work(key, title: "Anna Karenina")] }
          )

          Signals.call(verification: @row, client: client)

          assert_empty @row.reload.findings.foreign_work
          assert_empty client.calls.select { |call| call.first == :works_batch }
        end

        test "a hit on another work whose title agrees with ours is ignored" do
          row = run_signals(hits: {["isbn13", "9780140447934"] => [ol_hit("OL9W")]}, works: {"OL9W" => ol_work("OL9W", title: "War and Peace")})

          assert_empty row.findings.foreign_work
        end

        test "a work titled like a known translation of this book is not foreign" do
          ::Books::EditionCandidate.create!(book: @book, edition_key: "OL5M", title: "Wer die Nachtigall stört")
          ::Books::EditionCandidate.create!(book: @book, edition_key: "OL6M", title: "Krieg", subtitle: "und Frieden")
          row = run_signals(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL7W"), ol_hit("OL8W")]},
            works: {"OL7W" => ol_work("OL7W", title: "Wer die Nachtigall stört"), "OL8W" => ol_work("OL8W", title: "Krieg: und Frieden")}
          )

          assert_empty row.findings.foreign_work
        end

        test "a foreign work matching none of the book's candidates is still recorded" do
          ::Books::EditionCandidate.create!(book: @book, edition_key: "OL5M", title: "Krieg und Frieden")
          row = run_signals(hits: {["isbn13", "9780140447934"] => [ol_hit("OL7W")]}, works: {"OL7W" => ol_work("OL7W", title: "Anna Karenina")})

          assert_equal 1, row.findings.foreign_work.count
        end

        test "the article on the work's side is dropped too" do
          book = ::Books::Book.create!(title: "Bible")
          row = ::Books::Verification.create!(book: book, work_outcome: :keyed, new_key: "OL1W", run_id: "r", stage: :signals)
          Identifier.create!(identifiable: book, identifier_type: :books_work_isbn13, value: "9780140447934", source: :legacy)
          Signals.call(verification: row, client: FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit("OL7W")]}, works: {"OL7W" => ol_work("OL7W", title: "The Bible")}))

          assert_empty row.reload.findings.foreign_work
        end

        test "a leading article does not make a work foreign" do
          book = ::Books::Book.create!(title: "The Bible")
          row = ::Books::Verification.create!(book: book, work_outcome: :keyed, new_key: "OL1W", run_id: "r", stage: :signals)
          Identifier.create!(identifiable: book, identifier_type: :books_work_isbn13, value: "9780140447934", source: :legacy)
          Signals.call(verification: row, client: FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit("OL7W")]}, works: {"OL7W" => ol_work("OL7W", title: "Bible")}))

          assert_empty row.reload.findings.foreign_work
        end

        test "one identifier hitting two foreign works is one finding listing both, and a lump" do
          row = run_signals(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL8W"), ol_hit("OL7W")]},
            works: {"OL7W" => ol_work("OL7W", title: "Anna Karenina"), "OL8W" => ol_work("OL8W", title: "Resurrection")}
          )

          finding = row.findings.foreign_work.sole
          assert_equal "OL7W", finding.work_key
          assert_equal [{"key" => "OL7W", "title" => "Anna Karenina"}, {"key" => "OL8W", "title" => "Resurrection"}], finding.evidence["works"]
          assert row.lump_suspect
        end

        test "a re-run drops a stale foreign_work finding and recomputes the lump flag" do
          @row.update!(lump_suspect: true)
          Services::Books::Verification::Stamp.finding(@row, :foreign_work, "books_work_isbn13", "9780140447934", work_key: "OL7W", evidence: {"works" => []})

          row = run_signals(hits: {}, works: {})

          assert_empty row.findings.foreign_work
          refute row.lump_suspect
        end

        test "an unsure book has no work to exclude: titles alone decide" do
          @row.update!(work_outcome: :unsure, new_key: nil)
          row = run_signals(hits: {["isbn13", "9780140447934"] => [ol_hit("OL9W")]}, works: {"OL9W" => ol_work("OL9W", title: "War and Peace")})

          assert_empty row.findings.foreign_work
        end

        test "verified identifiers are not looked up" do
          identifiers(:war_and_peace_isbn13).update!(source: :worldcat)
          client = FakeOlClient.new

          Signals.call(verification: @row, client: client)

          assert_empty client.calls
        end

        test "an unknown identifier (404) is no hit" do
          row = run_signals(hits: {["isbn13", "9780140447934"] => ::Books::OpenLibrary::Exceptions::NotFoundError.new("no", 404)}, works: {})

          assert row.stage_done?
        end
      end
    end
  end
end
