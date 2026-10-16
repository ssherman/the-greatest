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
          assert_equal "Anna Karenina", row.findings.find_by!(work_key: "OL7W").evidence["title"]
          assert row.stage_done?
          assert_not_nil row.checked_at
        end

        test "one foreign work is recorded but is not a lump" do
          row = run_signals(hits: {["isbn13", "9780140447934"] => [ol_hit("OL7W")]}, works: {"OL7W" => ol_work("OL7W", title: "Anna Karenina")})

          assert_equal 1, row.findings.foreign_work.count
          refute row.lump_suspect
        end

        test "the settled work, its duplicates and its redirects are not foreign; a same-title work is ignored" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL2W", source: :open_library)
          hold(:books_work_goodreads_id, "1")
          hold(:books_work_goodreads_id, "2")
          redirected = ::Books::OpenLibrary::IdentifierHit.new(work_key: "OL3W", source: "openlibrary", redirected_from: ["OL1W"],
            edition_keys: [], id_type: "goodreads", value: "2")
          row = run_signals(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")], ["goodreads", "1"] => [ol_hit("OL2W", id_type: "goodreads", value: "1")],
                   ["goodreads", "2"] => [redirected]},
            works: {}
          )

          assert_empty row.findings.foreign_work
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
