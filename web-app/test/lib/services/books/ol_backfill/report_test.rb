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

        test "the latest failure shows the book, error and time; none when there is none" do
          assert_match(/Latest failure: none/, Report.call.join("\n"))

          war = books_books(:war_and_peace)
          crime = books_books(:crime_and_punishment)
          ::Books::OpenLibraryBackfill.create!(book: war, outcome: :failed, run_id: "run-1", error: "old error", updated_at: 2.days.ago)
          latest = ::Books::OpenLibraryBackfill.create!(book: crime, outcome: :failed, run_id: "run-1", error: "ServerError: down")

          text = Report.call.join("\n")

          assert_match(/Latest failure: book #{crime.id} "Crime and Punishment": ServerError: down at #{latest.updated_at.iso8601}/, text)
        end

        test "a confirmed row with a pair book is listed among the recent pairs; one without is not" do
          war = books_books(:war_and_peace)
          crime = books_books(:crime_and_punishment)
          got = books_books(:got)
          ::Books::OpenLibraryBackfill.create!(book: crime, outcome: :confirmed, run_id: "run-1", old_keys: ["OL262758W"], new_key: "OL262758W", pair_book: war)
          ::Books::OpenLibraryBackfill.create!(book: got, outcome: :confirmed, run_id: "run-1", old_keys: ["OL7W"], new_key: "OL7W")

          text = Report.call.join("\n")

          assert_match(/confirmed book #{crime.id} .*pair with book #{war.id}/, text)
          assert_no_match(/book #{got.id} "/, text)
        end

        test "a removed row is listed among the recent changes" do
          war = books_books(:war_and_peace)
          ::Books::OpenLibraryBackfill.create!(book: war, outcome: :removed, run_id: "run-1", old_keys: ["OL5W"])

          assert_match(/removed book #{war.id} "War and Peace": OL5W -> no key/, Report.call.join("\n"))
        end

        test "counts the books confirmed on Open Library's top answer after an abstain" do
          ::Books::OpenLibraryBackfill.create!(book: books_books(:got), outcome: :confirmed, run_id: "run-1", confirmed_on_abstain: true)
          ::Books::OpenLibraryBackfill.create!(book: books_books(:clash), outcome: :confirmed, run_id: "run-1")

          assert_match(/Confirmed on Open Library's top answer \(abstained\): 1/, Report.call.join("\n"))
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
