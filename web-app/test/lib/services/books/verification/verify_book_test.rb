# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class VerifyBookTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace)
          @wc = FakeWcClient.new
        end

        def verify(ol) = VerifyBook.call(book: @book, ol_client: ol, wc_client: @wc, run_id: "run-1", wc_dump_date: "2025-09-04")

        test "a new book runs all four stages and ends done" do
          work = ol_work("OL1W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])
          ol = FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")]}, works: {"OL1W" => work},
            editions: {"OL1W" => [ol_edition("OL1M", title: "War and Peace", oclc: ["9"])]})

          result = verify(ol)

          assert result.success?
          assert result.data.row.stage_done?
          assert_equal "open_library", @book.identifiers.find_by!(identifier_type: :books_work_oclc_id).source
        end

        test "a row stopped at worldcat resumes there and never repeats stages 1 and 2" do
          row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, new_key: "OL1W", run_id: "old", stage: :worldcat)
          ol = FakeOlClient.new

          verify(ol)

          assert row.reload.stage_done?
          assert ol.calls.none? { |call| %i[resolve editions].include?(call.first) }
          assert_equal "run-1", row.run_id
        end

        test "a WorldCat error stops the book at worldcat with its earlier stages kept" do
          row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, new_key: "OL1W", run_id: "old", stage: :identifiers)
          ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :added, identifier_type: :books_work_oclc_id, value: "1")
          ol = FakeOlClient.new(works: {"OL1W" => ol_work("OL1W", title: "War and Peace")}, editions: {"OL1W" => []})
          @wc = FakeWcClient.new(errors: [::Books::WorldCat::Exceptions::TimeoutError.new("slow")])

          assert_raises(::Books::WorldCat::Exceptions::TimeoutError) { verify(ol) }
          assert row.reload.stage_worldcat?
          assert_equal 1, row.findings.count
        end
      end
    end
  end
end
