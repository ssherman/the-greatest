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
          assert_equal({"applied" => 1}, data[:by_outcome])
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

        test "unlisted genres are alias suggestions grouped by case-folded name and genre" do
          satire = ::Books::Category.create!(name: "Report Satire", category_type: "genre")
          deleted = ::Books::Category.create!(name: "Report Gone", category_type: "genre", deleted: true)
          subject = ::Books::Category.create!(name: "Report Subject", category_type: "subject")
          row(@a, answer: {"unlisted_genres" => [{"name" => "Satirical Novel", "closest_id" => satire.id},
            {"name" => "satirical novel", "closest_id" => satire.id}, {"name" => "Odd One", "closest_id" => deleted.id}]})
          row(@b, answer: {"unlisted_genres" => [{"name" => "Satirical novel", "closest_id" => satire.id},
            {"name" => "Odd one", "closest_id" => subject.id}, {"name" => "Nothing Close", "closest_id" => nil}, "Legacy String"]})
          assert_equal [
            {name: "satirical novel", genre_id: satire.id, genre_name: "Report Satire", count: 2},
            {name: "legacy string", genre_id: nil, genre_name: nil, count: 1},
            {name: "nothing close", genre_id: nil, genre_name: nil, count: 1},
            {name: "odd one", genre_id: nil, genre_name: nil, count: 2}
          ].sort_by { |h| [-h[:count], h[:name]] }, Report.call.data[:unlisted_genres]
        end

        test "an unresolvable Wikidata label is counted, taking the task's closest id for the same name on that book" do
          ::Books::Category.create!(name: "Known Genre", category_type: "genre")
          satire = ::Books::Category.create!(name: "Report Satire", category_type: "genre")
          row(@a, answer: {"unlisted_genres" => [{"name" => "Weird Fiction", "closest_id" => satire.id}]},
            dossier: {"wikidata" => {"genres" => ["Known Genre", "weird fiction", "Space Opera"]}})
          row(@b, dossier: {"wikidata" => {"genres" => ["Space Opera"]}})
          assert_equal [
            {name: "space opera", genre_id: nil, genre_name: nil, count: 2},
            {name: "weird fiction", genre_id: satire.id, genre_name: "Report Satire", count: 1}
          ], Report.call.data[:unlisted_genres]
        end

        test "unlisted_limit caps the suggestions and nil lifts the cap" do
          row(@a, answer: {"unlisted_genres" => [{"name" => "aa", "closest_id" => nil}, {"name" => "bb", "closest_id" => nil}]})
          assert_equal 1, Report.call(unlisted_limit: 1).data[:unlisted_genres].size
          assert_equal 2, Report.call(unlisted_limit: nil).data[:unlisted_genres].size
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
