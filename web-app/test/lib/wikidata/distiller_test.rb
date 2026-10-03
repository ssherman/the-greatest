# frozen_string_literal: true

require "test_helper"

module Wikidata
  class DistillerTest < ActiveSupport::TestCase
    def real_entity
      JSON.parse(file_fixture("wikidata/wbgetentities_Q7243.json").read)["entities"]["Q7243"]
    end

    test "distills a real entity into the fields the author steps read" do
      payload = Distiller.call(real_entity)

      assert_equal "Q7243", payload["id"]
      assert_equal "Leo Tolstoy", payload["label"]
      assert_equal "Russian author (1828–1910)", payload["description"]
      assert_includes payload["aliases"], "Leo Tolstoi"
      assert_includes payload["instance_of"], "Q5"
      assert_includes payload["gender"], "Q6581097"
      # Wikidata may carry both a Gregorian and a Julian date for 1828; both are day precision.
      assert_equal [1828], payload["birth"].map { |date| date["year"] }.uniq
      assert payload["birth"].all? { |date| date["precision"] == 11 }
      assert_equal [1910], payload["death"].map { |date| date["year"] }.uniq
      assert_equal ["Q34266"], payload["citizenships"]
      assert_includes payload["occupations"], "Q36180"
      assert_equal ["Лев Никола́евич Толсто́й"], payload["native_names"]
      assert_equal ["Л. Н. Т.", "Л. Н."], payload["pseudonyms"]
      assert_equal ["96987389"], payload["identifiers"]["viaf"]
      assert_equal ["0000000122424494"], payload["identifiers"]["isni"]
      assert_equal ["n79068416"], payload["identifiers"]["lcnaf"]
      # The fetched fixture carries OL7555476A at rank "deprecated" (measured 2026-09-27), so
      # best-rank filtering excludes it; only OL26783A survives.
      assert_equal ["OL26783A"], payload["identifiers"]["openlibrary"]
      assert_equal ["128382"], payload["identifiers"]["goodreads"]
      assert_equal ["tolstoyleo"], payload["identifiers"]["librarything"]
      assert_equal "Leo Tolstoy", payload["enwiki_title"]
      assert_equal 3, payload["sitelink_count"]
    end

    test "uses only best-rank statements: preferred when any, never deprecated" do
      entity = wikidata_entity("Q1", label: "X", claims: {
        "P569" => [wikidata_time_statement(1900, rank: "preferred"), wikidata_time_statement(1901)],
        "P27" => [wikidata_item_statement("Q30", rank: "deprecated"), wikidata_item_statement("Q145")]
      })

      payload = Distiller.call(entity)

      assert_equal [{"year" => 1900, "precision" => 9}], payload["birth"]
      assert_equal ["Q145"], payload["citizenships"]
    end

    test "keeps somevalue dates as unknown and BCE years as negative" do
      payload = Distiller.call(wikidata_entity("Q1", label: "X", born: :unknown, died: {year: -347, precision: 9}))

      assert_equal [{"unknown" => true}], payload["birth"]
      assert_equal [{"year" => -347, "precision" => 9}], payload["death"]
    end

    test "handles an entity with no English label, aliases, claims or sitelinks" do
      payload = Distiller.call({"id" => "Q9", "labels" => {}, "aliases" => {}, "claims" => {}, "sitelinks" => {}})

      assert_nil payload["label"]
      assert_equal [], payload["aliases"]
      assert_equal [], payload["instance_of"]
      assert_equal 0, payload["sitelink_count"]
    end

    # Wikidata now keeps many names only under "mul" (default for all
    # languages): Victor Hugo's item has no English label at all.
    test "falls back to the all-languages label and adds its aliases, preferring English where both exist" do
      mul_only = Distiller.call({"id" => "Q535", "labels" => {"mul" => {"language" => "mul", "value" => "Victor Hugo"}},
        "aliases" => {"mul" => [{"language" => "mul", "value" => "Victor-Marie Hugo"}], "en" => [{"language" => "en", "value" => "Hugo"}]},
        "claims" => {}, "sitelinks" => {}})
      both = Distiller.call({"id" => "Q1", "labels" => {"en" => {"language" => "en", "value" => "Leo Tolstoy"},
                                                        "mul" => {"language" => "mul", "value" => "Lev Tolstoy"}}, "aliases" => {}, "claims" => {}, "sitelinks" => {}})

      assert_equal "Victor Hugo", mul_only["label"]
      assert_equal ["Hugo", "Victor-Marie Hugo"], mul_only["aliases"]
      assert_equal "Leo Tolstoy", both["label"]
    end

    test "refuses a missing entity" do
      assert_raises(::Wikimedia::Exceptions::ParseError) { Distiller.call({"id" => "Q0", "missing" => true}) }
      assert_raises(::Wikimedia::Exceptions::ParseError) { Distiller.call(nil) }
    end
  end
end
