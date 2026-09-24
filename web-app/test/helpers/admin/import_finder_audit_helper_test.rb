require "test_helper"

module Admin
  class ImportFinderAuditHelperTest < ActionView::TestCase
    include Admin::ImportFinderAuditHelper

    test "audit_query_line joins title, creators and year" do
      decision = MatchDecision.new(query: {"title" => "Dune", "author_names" => ["Frank Herbert"], "year" => 1965})
      assert_equal "Dune | by Frank Herbert | (1965)", audit_query_line(decision)
    end

    test "audit_query_line reads name and artist for other domains and falls back to the raw hash" do
      assert_equal "Pink Floyd", audit_query_line(MatchDecision.new(query: {"name" => "Pink Floyd"}))
      assert_equal "Animals | by Music::Artist#1", audit_query_line(MatchDecision.new(query: {"title" => "Animals", "artist" => "Music::Artist#1"}))
      assert_equal({"igdb_id" => 7}.to_json, audit_query_line(MatchDecision.new(query: {"igdb_id" => 7})))
    end

    test "audit_record_label prefers title, then name" do
      assert_equal "War and Peace", audit_record_label(books_books(:war_and_peace))
      assert_equal books_authors(:tolstoy).name, audit_record_label(books_authors(:tolstoy))
    end

    test "audit_shared_identifiers intersects the query's identifiers with the candidate's and adds the matched one" do
      decision = MatchDecision.new(query: {"isbn13" => ["111", "222"], "asin" => ["B1"]})
      candidate = {"evidence" => {"identifiers" => [{"type" => "books_work_isbn13", "value" => "222"}, {"type" => "books_work_asin", "value" => "B9"}], "matched_identifier" => {"type" => "books_work_asin", "value" => "B1"}}}

      assert_equal %w[222 B1], audit_shared_identifiers(decision, candidate)
      assert_empty audit_shared_identifiers(MatchDecision.new(query: {}), {"evidence" => {}})
    end
  end
end
