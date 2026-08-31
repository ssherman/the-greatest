# frozen_string_literal: true

require "test_helper"

class Viaf::PersonTest < ActiveSupport::TestCase
  def payload(overrides = {})
    {
      "viaf_id" => "96987389",
      "name_type" => "Personal",
      "birth_date" => "1828-09-09",
      "death_date" => "1910-11-20",
      "gender" => "b",
      "source_ids" => {"LC" => "n79068416", "ISNI" => "0000000122424494", "WKP" => "Q7243"},
      "main_headings" => [{"source" => "LC", "name" => "Tolstoy, Leo"}],
      "names" => ["Tolstoi, Lev Nikolaevich"],
      "nationality" => ["RU"],
      "language" => ["rus"],
      "occupation" => ["authors"],
      "field_of_activity" => ["literature"]
    }.merge(overrides)
  end

  def person(overrides = {})
    Viaf::Person.from_payload(payload(overrides))
  end

  test "exposes the raw payload fields" do
    subject = person

    assert_equal "96987389", subject.viaf_id
    assert_equal "Personal", subject.name_type
    assert_equal "1828-09-09", subject.birth_date
    assert_equal "1910-11-20", subject.death_date
    assert_equal "b", subject.gender_code
    assert_equal({"LC" => "n79068416", "ISNI" => "0000000122424494", "WKP" => "Q7243"}, subject.source_ids)
    assert_equal [{"source" => "LC", "name" => "Tolstoy, Leo"}], subject.main_headings
    assert_equal ["Tolstoi, Lev Nikolaevich"], subject.names
    assert_equal ["RU"], subject.nationality
    assert_equal ["rus"], subject.language
    assert_equal ["authors"], subject.occupation
    assert_equal ["literature"], subject.field_of_activity
  end

  test "derives birth and death years from day-precision dates" do
    assert_equal 1828, person.birth_year
    assert_equal 1910, person.death_year
  end

  test "derives years from year-precision integers" do
    subject = person("birth_date" => 1473, "death_date" => 1531)

    assert_equal 1473, subject.birth_year
    assert_equal 1531, subject.death_year
  end

  test "handles BCE years" do
    assert_equal(-384, person("birth_date" => "-384").birth_year)
  end

  test "returns nil years when dates are absent" do
    subject = person("birth_date" => nil, "death_date" => nil)

    assert_nil subject.birth_year
    assert_nil subject.death_year
  end

  test "maps gender codes to the Books::Author enum values" do
    assert_equal :male, person("gender" => "b").gender
    assert_equal :female, person("gender" => "a").gender
    assert_equal :unspecified, person("gender" => "u").gender
    assert_nil person("gender" => nil).gender
  end

  test "maps name type to the Books::Author kind enum" do
    assert_equal :person, person("name_type" => "Personal").kind
    assert_equal :organization, person("name_type" => "Corporate").kind
    assert_nil person("name_type" => "UniformTitle").kind
  end

  # AutoSuggest sends "personal"/"corporate" (lowercase); Cluster sends
  # "Personal"/"Corporate". The lookup must not depend on which endpoint the
  # value came from.
  test "maps name type to kind case-insensitively" do
    assert_equal :person, person("name_type" => "personal").kind
    assert_equal :organization, person("name_type" => "corporate").kind
  end

  test "exposes mapped identifiers" do
    subject = person

    assert_equal "n79068416", subject.lcnaf
    assert_equal "0000000122424494", subject.isni
    assert_equal "Q7243", subject.wikidata_qid
  end

  test "returns nil for identifiers the cluster lacks" do
    assert_nil person("source_ids" => {}).isni
  end

  test "preferred_name uses the first main heading" do
    assert_equal "Tolstoy, Leo", person.preferred_name
  end

  test "preferred_name falls back to the first alternate name" do
    assert_equal "Tolstoi, Lev Nikolaevich", person("main_headings" => []).preferred_name
  end

  test "preferred_name is nil when there are no names at all" do
    assert_nil person("main_headings" => [], "names" => []).preferred_name
  end
end
