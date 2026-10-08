# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class ReportTest < ActiveSupport::TestCase
        test "counts every outcome, ranked coverage, the latest run, author totals and recent replacements" do
          war = books_books(:war_and_peace)
          crime = books_books(:crime_and_punishment)
          ::RankedItem.create!(item: war, ranking_configuration: ranking_configurations(:books_global), rank: 1, score: 99)
          ::Books::OpenLibraryBackfill.create!(book: war, outcome: :replaced, run_id: "run-1", old_keys: ["OL5W"], new_key: "OL1W",
            author_changes: {"added" => [[1, "OL1A"], [2, "OL2A"]], "pairs" => [[3, 4, "OL3A"]], "conflicts" => []})
          ::Books::OpenLibraryBackfill.create!(book: crime, outcome: :duplicate_pair, run_id: "run-2", new_key: "OL262758W", pair_book: war)

          text = Report.call.join("\n")

          assert_match(/replaced\s+1/, text)
          assert_match(/duplicate_pair\s+1/, text)
          assert_match(/keyed\s+0/, text)
          assert_match(/Ranked books checked: 1 of 1/, text)
          assert_match(/Latest run run-2: 1 books/, text)
          assert_match(/Author keys added: 2, author pairs: 1, author conflicts: 0/, text)
          assert_match(/replaced book #{war.id} "War and Peace": OL5W -> OL1W/, text)
          assert_match(/pair with book #{war.id}/, text)
        end

        test "an empty log reports zeros and no run" do
          text = Report.call.join("\n")

          assert_match(/Latest run: none/, text)
          assert_match(/Ranked books checked: 0 of/, text)
        end
      end
    end
  end
end
