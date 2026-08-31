# frozen_string_literal: true

require "test_helper"

class Viaf::SuggestionTest < ActiveSupport::TestCase
  # Real AutoSuggest result observed on 2026-08-30. Agency codes arrive as
  # variable top-level keys mixed in with the structural keys.
  def result(overrides = {})
    {
      "term" => "Tolstoy, Leo, graf, 1828-1910",
      "displayForm" => "Tolstoy, Leo, graf, 1828-1910",
      "nametype" => "personal",
      "lc" => "n79068416",
      "dnb" => "11864291x",
      "bnf" => "11926775",
      "viafid" => "96987389",
      "score" => "63074",
      "recordID" => "96987389"
    }.merge(overrides)
  end

  def suggestion(overrides = {})
    Viaf::Suggestion.from_result(result(overrides))
  end

  test "exposes the structural fields" do
    subject = suggestion

    assert_equal "96987389", subject.viaf_id
    assert_equal "Tolstoy, Leo, graf, 1828-1910", subject.term
    assert_equal "personal", subject.name_type
    assert_equal 63074, subject.score
  end

  test "exposes display_form independently of term" do
    subject = suggestion("displayForm" => "Tolstoy, Leo")

    assert_equal "Tolstoy, Leo, graf, 1828-1910", subject.term
    assert_equal "Tolstoy, Leo", subject.display_form
  end

  test "collects agency ids from the variable top-level keys" do
    subject = suggestion

    assert_equal "n79068416", subject.source_ids["lc"]
    assert_equal "11926775", subject.source_ids["bnf"]
  end

  test "excludes structural keys from source_ids" do
    subject = suggestion

    refute subject.source_ids.key?("term")
    refute subject.source_ids.key?("viafid")
    refute subject.source_ids.key?("score")
    refute subject.source_ids.key?("nametype")
    refute subject.source_ids.key?("recordID")
    refute subject.source_ids.key?("displayForm")
  end

  test "parses birth and death years out of the term string" do
    subject = suggestion

    assert_equal 1828, subject.birth_year
    assert_equal 1910, subject.death_year
  end

  test "parses an open-ended date range" do
    subject = suggestion("term" => "Smith, Jane, 1950-")

    assert_equal 1950, subject.birth_year
    assert_nil subject.death_year
  end

  test "returns nil years when the term carries no dates" do
    subject = suggestion("term" => "Anonymous")

    assert_nil subject.birth_year
    assert_nil subject.death_year
  end

  test "parses a death-only date range" do
    subject = suggestion("term" => "Smith, Jane, -1910")

    assert_nil subject.birth_year
    assert_equal 1910, subject.death_year
  end

  test "does not mistake a hyphenated surname for a date range" do
    subject = suggestion("term" => "Smith-Jones, Jane, 1828-1910")

    assert_equal 1828, subject.birth_year
    assert_equal 1910, subject.death_year
  end

  test "returns nil years for a term with only a roman numeral" do
    subject = suggestion("term" => "Louis XIV")

    assert_nil subject.birth_year
    assert_nil subject.death_year
  end

  test "returns nil years for a term with a short non-date number" do
    subject = suggestion("term" => "Henry, 8, King")

    assert_nil subject.birth_year
    assert_nil subject.death_year
  end

  test "maps nametype to the Books::Author kind enum" do
    assert_equal :person, suggestion("nametype" => "personal").kind
    assert_equal :organization, suggestion("nametype" => "corporate").kind
    assert_nil suggestion("nametype" => "uniformtitle").kind
  end
end
