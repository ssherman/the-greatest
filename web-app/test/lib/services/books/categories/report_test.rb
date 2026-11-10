# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Categories
      class ReportTest < ActiveSupport::TestCase
        setup do
          @a = new_book("Cat Report A")
          @b = new_book("Cat Report B")
        end

        def new_book(title)
          ::Books::Book.create!(title: title, first_published_year: 1900, original_language: languages(:english))
        end

        def row(book, label: "c1", outcome: :applied, mode: :knowledge, apply: {}, mapping: {}, answer: {}, dossier: nil, extra: {})
          facts = {"label" => label, "path" => "judge", "context" => "backfill", "answer" => answer,
                   "mapping" => {"resolved" => [], "unmatched" => []}.merge(mapping),
                   "apply" => {"added" => [], "confirmed" => [], "removed" => [], "held_back" => [],
                               "type" => {}}.merge(apply), "dossier" => dossier}.merge(extra)
          book.enrichments.create!(kind: "books.categories", mode: mode, outcome: outcome, facts: facts)
        end

        test "counts the latest row per book by type and reason" do
          row(@a, apply: {"added" => [{"type" => "genre"}, {"type" => "genre"}, {"type" => "subject"}]})
          row(@a, apply: {"added" => [{"type" => "genre"}], "confirmed" => [{"type" => "audience"}],
                          "removed" => [{"type" => "subject"}, {"type" => "subject"}],
                          "held_back" => [{"reason" => "cap"}, {"reason" => "cap"}, {"reason" => "low_confidence"}],
                          "type" => {"reason" => "type_conflict", "judged" => "novel", "held" => "essay"}})
          row(@b, label: "other")
          data = Report.call(label: "c1").data
          assert_equal [1, {"genre" => 1}, {"audience" => 1}, {"subject" => 2}, {"cap" => 2, "low_confidence" => 1}, {"type_conflict" => 1}],
            [data[:books], data[:added], data[:confirmed], data[:removed], data[:held_back], data[:type]]
          assert_equal [1.0, 2.0], [data[:avg_added_per_book], data[:avg_removed_per_book]]
          assert_equal [{book_id: @a.id, title: "Cat Report A", judged: "novel", held: "essay"}], data[:type_conflicts]
        end

        test "without a label spans every label" do
          row(@a)
          row(@b, label: "other")
          assert_equal 2, Report.call.data[:books]
        end

        test "unmatched proposals are case folded per type" do
          row(@a, mapping: {"unmatched" => [{"type" => "subject", "proposed" => "Whaling"}, {"type" => "genre", "proposed" => "Zed"}]})
          row(@b, mapping: {"unmatched" => [{"type" => "subject", "proposed" => "whaling"}]})
          assert_equal({"subject" => [["whaling", 2]], "genre" => [["zed", 1]]}, Report.call.data[:unmatched])
        end

        test "unlisted genres combine the task's names with unresolvable Wikidata labels" do
          ::Books::Category.create!(name: "Known Genre", category_type: "genre")
          row(@a, answer: {"unlisted_genres" => ["Space Opera", "space opera"]}, dossier: {"wikidata" => {"genres" => ["Known Genre", "Weird Fiction"]}})
          row(@b, answer: {"unlisted_genres" => ["Space opera", "Weird fiction"]})
          assert_equal [["space opera", 2], ["weird fiction", 2]], Report.call.data[:unlisted_genres].sort
        end

        test "research rows, cost and deferred research" do
          row(@b, extra: {"deferred_research" => true})
          row(@a, mode: :research)
          row(@b, label: "other")
          data = Report.call(label: "c1").data
          assert_equal [1, 1, 0.15], [data[:research_rows], data[:deferred_research], data[:research_cost_estimate]]
        end
      end
    end
  end
end
