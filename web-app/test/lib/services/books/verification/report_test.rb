# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class ReportTest < ActiveSupport::TestCase
        test "counts every outcome, ranked coverage, the latest run, author totals and recent replacements" do
          war = books_books(:war_and_peace)
          crime = books_books(:crime_and_punishment)
          ::RankedItem.create!(item: war, ranking_configuration: ranking_configurations(:books_global), rank: 1, score: 99)
          ::Books::Verification.create!(book: war, work_outcome: :replaced, run_id: "run-1", old_keys: ["OL5W"], new_key: "OL1W",
            author_changes: {"added" => [[1, "OL1A"], [2, "OL2A"]], "pairs" => [[3, 4, "OL3A"]], "conflicts" => []})
          ::Books::Verification.create!(book: crime, work_outcome: :duplicate_pair, run_id: "run-2", new_key: "OL262758W", pair_book: war)

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

        test "the report counts each second-chance route and samples its books" do
          war = books_books(:war_and_peace)
          ::Books::Verification.create!(book: war, work_outcome: :keyed, run_id: "r", lookup: :resolve_candidate, new_key: "OL1W")
          ::Books::Verification.create!(book: books_books(:crime_and_punishment), work_outcome: :keyed, run_id: "r", lookup: :worldcat_isbns, new_key: "OL2W")

          text = Report.call.join("\n")

          assert_match(/Settled by second-chance route:/, text)
          assert_match(/resolve_candidate\s+1/, text)
          assert_match(/worldcat_isbns\s+1/, text)
          assert_match(/exact_title\s+0/, text)
          assert_match(/held_key\s+0/, text)
          assert_match(/via resolve_candidate:\n\s+book #{war.id} "War and Peace"/, text)
        end

        test "the latest failure shows the book, error and time; none when there is none" do
          assert_match(/Latest failure: none/, Report.call.join("\n"))

          war = books_books(:war_and_peace)
          crime = books_books(:crime_and_punishment)
          ::Books::Verification.create!(book: war, work_outcome: :failed, run_id: "run-1", error: "old error", updated_at: 2.days.ago)
          latest = ::Books::Verification.create!(book: crime, work_outcome: :failed, run_id: "run-1", error: "ServerError: down")

          text = Report.call.join("\n")

          assert_match(/Latest failure: book #{crime.id} "Crime and Punishment": ServerError: down at #{latest.updated_at.iso8601}/, text)
        end

        test "a confirmed row with a pair book is listed among the recent pairs; one without is not" do
          war = books_books(:war_and_peace)
          crime = books_books(:crime_and_punishment)
          got = books_books(:got)
          ::Books::Verification.create!(book: crime, work_outcome: :confirmed, run_id: "run-1", old_keys: ["OL262758W"], new_key: "OL262758W", pair_book: war)
          ::Books::Verification.create!(book: got, work_outcome: :confirmed, run_id: "run-1", old_keys: ["OL7W"], new_key: "OL7W")

          text = Report.call.join("\n")

          assert_match(/confirmed book #{crime.id} .*pair with book #{war.id}/, text)
          assert_no_match(/confirmed book #{got.id} "/, text)
        end

        test "a removed row is listed among the recent changes" do
          war = books_books(:war_and_peace)
          ::Identifier.create!(identifiable: war, identifier_type: :books_work_openlibrary_id, value: "OL6W")
          ::Books::Verification.create!(book: war, work_outcome: :removed, run_id: "run-1", old_keys: ["OL5W", "OL6W"])

          assert_match(/removed book #{war.id} "War and Peace": OL5W -> no key/, Report.call.join("\n"))
        end

        test "counts the books confirmed on Open Library's top answer after an abstain" do
          ::Books::Verification.create!(book: books_books(:got), work_outcome: :confirmed, run_id: "run-1", confirmed_on_abstain: true)
          ::Books::Verification.create!(book: books_books(:clash), work_outcome: :confirmed, run_id: "run-1")

          assert_match(/Confirmed on Open Library's top answer \(abstained\): 1/, Report.call.join("\n"))
        end

        test "the report counts cohorts, stages, findings, lump suspects and candidates" do
          row = ::Books::Verification.create!(book: books_books(:war_and_peace), work_outcome: :keyed, run_id: "r", stage: :done, lump_suspect: true)
          ::Books::VerificationFinding.create!(verification: row, book: row.book, kind: :wrong_identifier, identifier_type: :books_work_isbn13, value: "1")
          ::Books::EditionCandidate.create!(book: row.book, edition_key: "OL2M")

          text = Report.call.join("\n")

          assert_match(/pre_import\s+done\s+1/, text)
          assert_match(/wrong_identifier\s+1/, text)
          assert_match(/Lump suspects: 1/, text)
          assert_match(/Edition candidates: 1/, text)
        end

        test "the report shows ranked identifier coverage by type and source" do
          book = books_books(:war_and_peace)
          ::RankedItem.create!(item: book, ranking_configuration: ::Books::RankingConfiguration.default_primary, rank: 1, score: 1)
          Identifier.create!(identifiable: book, identifier_type: :books_work_oclc_id, value: "1", source: :worldcat)

          assert_match(/books_work_oclc_id\s+worldcat\s+1/, Report.call.join("\n"))
        end

        test "samples print our title and authors beside the evidence" do
          row = ::Books::Verification.create!(book: books_books(:war_and_peace), work_outcome: :unsure, run_id: "r", stage: :done)
          ::Books::VerificationFinding.create!(verification: row, book: row.book, kind: :wrong_identifier, identifier_type: :books_work_isbn13,
            value: "9780307266934", evidence: {"records" => [{"title" => "Gloriana", "creator" => "Moorcock, Michael"}]})

          assert_match(/War and Peace.*Tolstoy.*9780307266934.*Gloriana.*Moorcock/, Report.call.join("\n"))
        end

        test "samples show stage 2's trusted Open Library writes with their edition evidence" do
          row = ::Books::Verification.create!(book: books_books(:war_and_peace), work_outcome: :unsure, run_id: "r", stage: :done)
          ::Books::VerificationFinding.create!(verification: row, book: row.book, kind: :added, source: :open_library, identifier_type: :books_work_isbn13,
            value: "9780307266934", evidence: {"edition_key" => "OL1M", "title" => "War and Peace"})

          assert_match(/9780307266934.*OL1M/, Report.call.join("\n"))
        end

        test "samples survive a book with no authors and evidence with missing keys" do
          book = ::Books::Book.create!(title: "Orphan")
          row = ::Books::Verification.create!(book: book, work_outcome: :keyed, run_id: "r", new_key: "OL1W", stage: :done)
          ::Books::VerificationFinding.create!(verification: row, book: book, kind: :wrong_identifier, identifier_type: :books_work_isbn13, value: "5", evidence: {})

          assert_match(/Orphan/, Report.call.join("\n"))
        end

        test "work outcome samples show Open Library's title and authors when a client is given" do
          row = ::Books::Verification.create!(book: books_books(:war_and_peace), work_outcome: :keyed, run_id: "r", new_key: "OL1W", stage: :done)
          work = stub(title: "Voyna i mir", author_names: ["Leo Tolstoy"])
          client = stub
          client.expects(:works_batch).with(["OL1W"]).returns({"OL1W" => work})

          assert_match(/book #{row.book_id} .*-> OL1W.*Voyna i mir.*Leo Tolstoy/, Report.call(client: client).join("\n"))
        end

        test "an Open Library error prints the keys alone" do
          ::Books::Verification.create!(book: books_books(:war_and_peace), work_outcome: :keyed, run_id: "r", new_key: "OL1W", stage: :done)
          client = stub
          client.stubs(:works_batch).raises(::Books::OpenLibrary::Exceptions::Error.new("down"))

          assert_match(/-> OL1W/, Report.call(client: client).join("\n"))
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
