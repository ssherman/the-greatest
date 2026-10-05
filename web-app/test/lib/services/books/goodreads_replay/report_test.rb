require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class ReportTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete, legacy_import_id: 1)
          ::Books::GoodreadsImport.create!(user: users(:editor_user), source: :legacy_replay, status: :failed, legacy_import_id: 2,
            error: "not a CSV upload: video/mp4")
          edition = goodreads_edition
          {agrees: 3, duplicate: 1, disagrees: 1, unmatched: 1, no_legacy_choice: 2}.each do |finding, count|
            count.times { import.rows.create!(row_number: import.rows.count + 1, goodreads_edition: edition, replay_finding: finding) }
          end
          import.rows.create!(row_number: 99, goodreads_edition: edition)
          ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition, outcome: :matched,
            confidence: :high, decided_by: :ai, ai_chat: ai_chats(:general_chat))
          ::Books::RepairVerdict.create!(kind: :relink, subject_key: "user:1:book:2:goodreads:3", decided_by: :ai,
            confidence: :high, payload: {"user_id" => 1, "from_book_id" => 2, "to_book_id" => 4})
          ::Books::RepairVerdict.create!(kind: :strip_identifier, subject_key: "book:7:x", decided_by: :rule, confidence: :certain,
            status: :approved, applied_at: Time.current, payload: {"book_id" => 7, "remove" => [], "add" => []})
        end

        def markdown
          Report.call(now: Time.zone.parse("2026-10-06 12:00")).data[:markdown]
        end

        test "opens with the date, the database and the command that produced it" do
          assert_match(/\A# Goodreads legacy replay\n\n\*\*Measured 2026-10-06\*\*/, markdown)
          assert_includes markdown, "bin/rails \"books:goodreads_replay:report[../docs/data-quality/goodreads-replay.md]\""
        end

        test "counts imports by status, and rows by finding with the agreement rate" do
          assert_includes markdown, "| complete | 1 |"
          assert_includes markdown, "| failed | 1 |"
          assert_includes markdown, "| agrees | 3 |"
          assert_includes markdown, "| not compared yet | 1 |"
          # (agrees + duplicate) / rows with a legacy choice and a final finding = 4 / 6
          assert_includes markdown, "Agreement: **66.7%** (4 of 6 rows with a legacy choice)"
        end

        test "breaks verdicts down by kind, decider and confidence, and counts the matching AI calls" do
          assert_includes markdown, "| relink | ai | high | 1 | 0 | 0 | 0 |"
          assert_includes markdown, "| strip_identifier | rule | certain | 0 | 1 | 0 | 1 |"
          assert_includes markdown, "Matching AI calls on replay editions: 1"
        end

        test "sample lists unreviewed approved verdicts of a kind" do
          lines = Report.sample(kind: "strip_identifier", count: 50)

          assert_equal 1, lines.size
          assert_match(/\A#\d+ On book #7/, lines.first)
          assert_empty Report.sample(kind: "relink", count: 50)
        end
      end
    end
  end
end
