# frozen_string_literal: true

require "test_helper"

module Books
  module OpenLibrary
    class CandidateTest < ActiveSupport::TestCase
      def build_record(verdict: "accept", diff: [], record: nil)
        {
          "key" => {"source" => "openlibrary", "key" => "OL468431W"},
          "score" => 0.98,
          "rules" => ["identifier", "author_title_fp"],
          "margin" => 0.4,
          "verdict" => verdict,
          "evidence" => {"title_similarity" => {"value" => 1.0, "weight" => 1.0}},
          "conflicts" => [],
          "diff" => diff,
          "record" => record
        }
      end

      def source_version
        {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
         "pipeline_version" => 1, "matcher_version" => 2}
      end

      test "#accept? #abstain? #reject? read verdict, never re-decide" do
        assert Candidate.from_record(build_record(verdict: "accept"), source_version: source_version).accept?
        assert Candidate.from_record(build_record(verdict: "abstain"), source_version: source_version).abstain?
        assert Candidate.from_record(build_record(verdict: "reject"), source_version: source_version).reject?
      end

      test "#accept? is false for a non-accept verdict, not merely un-asserted" do
        candidate = Candidate.from_record(build_record(verdict: "reject"), source_version: source_version)

        assert_not candidate.accept?
        assert_not candidate.abstain?
      end

      test "#fills #conflicts #enrichments select diff entries by kind; agreement, absent and an unknown kind land in none" do
        diff = [
          {"field" => "title", "ours" => "The Great Gatsby", "theirs" => "The Great Gatsby", "kind" => "agreement"},
          {"field" => "description", "ours" => nil, "theirs" => "...", "kind" => "fill"},
          {"field" => "subtitle", "ours" => nil, "theirs" => nil, "kind" => "absent"},
          {"field" => "subjects", "ours" => [], "theirs" => ["Fiction"], "kind" => "fill"},
          {"field" => "authors", "ours" => ["A"], "theirs" => ["A", "B"], "kind" => "enrichment"},
          {"field" => "first_published_year", "ours" => 1925, "theirs" => 1926, "kind" => "conflict"},
          {"field" => "mystery_field", "ours" => 1, "theirs" => 2, "kind" => "some_future_kind"}
        ]
        candidate = Candidate.from_record(build_record(diff: diff), source_version: source_version)

        assert_equal ["description", "subjects"], candidate.fills.map(&:field)
        assert_equal ["first_published_year"], candidate.conflicts.map(&:field)
        assert_equal ["authors"], candidate.enrichments.map(&:field)

        classified = candidate.fills + candidate.conflicts + candidate.enrichments
        assert_not_includes classified.map(&:field), "title"
        assert_not_includes classified.map(&:field), "subtitle"
        assert_not_includes classified.map(&:field), "mystery_field"
      end

      test "diff entries carry field, ours, theirs and kind as served" do
        diff = [{"field" => "title", "ours" => "Dune", "theirs" => "dune", "kind" => "agreement"}]
        candidate = Candidate.from_record(build_record(diff: diff), source_version: source_version)
        entry = candidate.diff.first

        assert_equal "title", entry.field
        assert_equal "Dune", entry.ours
        assert_equal "dune", entry.theirs
        assert_equal "agreement", entry.kind
      end

      test "#work_key and #source come from the served key pair" do
        candidate = Candidate.from_record(build_record, source_version: source_version)

        assert_equal "OL468431W", candidate.work_key
        assert_equal "openlibrary", candidate.source
      end

      test "conflicting_features exposes the served conflicts array" do
        record = build_record.merge("conflicts" => ["first_published_year"])
        candidate = Candidate.from_record(record, source_version: source_version)

        assert_equal ["first_published_year"], candidate.conflicting_features
      end

      test "evidence is exposed with symbol keys" do
        candidate = Candidate.from_record(build_record, source_version: source_version)

        assert_equal 1.0, candidate.evidence.dig(:title_similarity, :value)
      end

      test "a null record maps to a nil Candidate#record" do
        candidate = Candidate.from_record(build_record(record: nil), source_version: source_version)

        assert_nil candidate.record
      end

      test "a present record builds a Work via Work.from_record" do
        work_record = {
          "key" => {"source" => "openlibrary", "key" => "OL468431W"},
          "redirected_from" => [],
          "title" => "The Great Gatsby",
          "subtitle" => nil,
          "description" => "...",
          "authors" => [{"key" => {"source" => "openlibrary", "key" => "OL27349A"}, "name" => "F. Scott Fitzgerald"}],
          "subjects" => ["Fiction"],
          "year_evidence" => nil,
          "popularity" => nil
        }
        candidate = Candidate.from_record(build_record(record: work_record), source_version: source_version)

        assert_instance_of Books::OpenLibrary::Work, candidate.record
        assert_equal "OL468431W", candidate.record.key
        assert_equal "The Great Gatsby", candidate.record.title
      end
    end
  end
end
