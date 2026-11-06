# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Origin
      class ReportTest < ActiveSupport::TestCase
        setup do
          @american = ::Books::Country.find_or_create_by!(name: "American")
          @book = new_book("Report Book A")
          @other = new_book("Report Book B")
        end

        def new_book(title)
          ::Books::Book.create!(title: title, first_published_year: 1900, original_language: languages(:english))
        end

        def row(book, label:, path: "judge", reason: "filled", outcome: :applied, mode: :knowledge, origin: {}, extra: {})
          facts = {"label" => label, "path" => path, "context" => "backfill", "origin" => {"reason" => reason}.merge(origin)}.merge(extra)
          book.enrichments.create!(kind: "books.origin", mode: mode, outcome: outcome, facts: facts)
        end

        test "report counts the latest row per book in a label" do
          row(@book, label: "r1", path: "judge", reason: "low_confidence", outcome: :nothing_to_apply)
          row(@book, label: "r1", path: "shortcut", reason: "filled", origin: {"country" => "American"})
          row(@other, label: "r2")
          data = Report.call(label: "r1").data
          assert_equal [1, {"shortcut" => 1}, {"filled" => 1}, [["American", 1]]],
            [data[:books], data[:by_path], data[:by_reason], data[:applied_countries]]
        end

        test "report without a label spans every label" do
          row(@book, label: "r1")
          row(@other, label: "r2")
          assert_equal 2, Report.call.data[:books]
        end

        test "report lists disagreements and no_match strings" do
          row(@book, label: "r1", reason: "disagreement", outcome: :nothing_to_apply,
            origin: {"country" => "British", "held" => ["American"]})
          row(@other, label: "r1", reason: "no_match", outcome: :nothing_to_apply, origin: {"raw" => "Chinese American"})
          data = Report.call(label: "r1").data
          assert_equal "British", data[:disagreements].sole[:proposed]
          assert_equal ["American"], data[:disagreements].sole[:held]
          assert_equal "Report Book A", data[:disagreements].sole[:title]
          assert_equal [["Chinese American", 1]], data[:no_match]
        end

        test "research rows count every row in the label and price at 0.15" do
          row(@book, label: "r1", mode: :research)
          row(@book, label: "r1", mode: :research, extra: {"deferred_research" => true})
          row(@other, label: "r2", mode: :research)
          data = Report.call(label: "r1").data
          assert_equal [2, 0.3], [data[:research_rows], data[:research_cost_estimate].round(2)]
          assert_equal 1, data[:deferred_research]
        end
      end
    end
  end
end
