# frozen_string_literal: true

require "test_helper"

module Wikidata
  class WorkDistillerTest < ActiveSupport::TestCase
    def entity(id) = JSON.parse(file_fixture("wikidata/wbgetentities_#{id}.json").read)["entities"][id]

    test "distills a novel into the fields the evidence reads" do
      payload = WorkDistiller.call(entity("Q161531"))

      assert_equal "Q161531", payload["id"]
      assert_equal "Lolita", payload["label"]
      assert_equal "1955 novel by Vladimir Nabokov", payload["description"]
      assert_equal ["Q8261"], payload["instance_of"]
      assert_equal ["Q2678"], payload["authors"]
      assert_equal ["Q30"], payload["countries"]
      assert_equal ["Q1860"], payload["languages"]
      assert_equal ["Q8253"], payload["genres"]
      assert_equal ["Q1297"], payload["narrative_locations"]
      assert_equal ["Q1"], payload["set_in_periods"]
      assert_equal ["Q8261"], payload["forms"]
      assert_equal "Lolita", payload["enwiki_title"]
    end

    test "deprecated statements are dropped and preferred ones win" do
      payload = WorkDistiller.call(entity("Q161531"))

      assert_not_includes payload["countries"], "Q145"
      assert_equal ["Q1"], payload["main_subjects"]
    end

    test "publication years keep only year precision or finer" do
      assert_equal [1955], WorkDistiller.call(entity("Q161531"))["publication_years"]
    end

    test "identifiers are arrays keyed by source, empty when absent" do
      assert_equal({"goodreads_book" => ["929"], "openlibrary" => ["OL1168083W"], "oclc" => ["1234"]},
        WorkDistiller.call(entity("Q161531"))["identifiers"])
      assert_equal({"goodreads_book" => [], "openlibrary" => [], "oclc" => []}, WorkDistiller.call(entity("Q999001"))["identifiers"])
    end

    test "an edition carries its work in edition_of" do
      assert_equal ["Q161531"], WorkDistiller.call(entity("Q999001"))["edition_of"]
    end

    test "rejects something that is not an entity" do
      assert_raises(::Wikimedia::Exceptions::ParseError) { WorkDistiller.call({"missing" => ""}) }
    end
  end
end
