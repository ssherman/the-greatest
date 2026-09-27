# frozen_string_literal: true

require "test_helper"

module Wikidata
  class EntityTest < ActiveSupport::TestCase
    def entity(**options)
      Entity.from_payload(Distiller.call(wikidata_entity("Q1", label: "Leo Tolstoy", **options)))
    end

    test "a human, a pseudonym and a collective pseudonym are persons; a book is not" do
      assert entity(types: ["Q5"]).person?
      assert entity(types: ["Q61002"]).person?
      assert entity(types: ["Q16017119"]).person?
      assert_not entity(types: ["Q7725634"]).person?
    end

    test "names are the label and the English aliases" do
      assert_equal ["Leo Tolstoy", "Lev Tolstoy"], entity(aliases: ["Lev Tolstoy", "Leo Tolstoy"]).names
    end

    test "every scalar and list reader surfaces its distilled field" do
      subject = entity(
        aliases: ["Lev Tolstoy"], description: "Russian author", gender: ["Q6581097"],
        citizenships: ["Q34266"], occupations: ["Q36180"], native_names: ["Лев Никола́евич Толсто́й"],
        pseudonyms: ["Л. Н."], enwiki: "Leo Tolstoy", sitelinks: 3, died: {year: 1910, precision: 8}
      )

      assert_equal "Q1", subject.id
      assert_equal "Leo Tolstoy", subject.label
      assert_equal "Russian author", subject.description
      assert_equal ["Lev Tolstoy"], subject.aliases
      assert_equal ["Q6581097"], subject.gender_ids
      assert_equal ["Q34266"], subject.citizenship_ids
      assert_equal ["Q36180"], subject.occupation_ids
      assert_equal ["Лев Никола́евич Толсто́й"], subject.native_names
      assert_equal ["Л. Н."], subject.pseudonyms
      assert_equal "Leo Tolstoy", subject.enwiki_title
      assert_equal 3, subject.sitelink_count
      assert_equal "imprecise", subject.death.reason
    end

    test "a year at year precision or finer is usable" do
      subject = entity(born: {year: 1828, precision: 11}, died: 1910)

      assert_equal [1828, 1910], [subject.birth_year, subject.death_year]
      assert_nil subject.birth.reason
    end

    test "every reason a year is not usable" do
      assert_equal "null", entity.birth.reason
      assert_equal "unknown", entity(born: :unknown).birth.reason
      assert_equal "imprecise", entity(born: {year: 1820, precision: 8}).birth.reason
      assert_equal "disagreeing", entity(born: [1828, 1829]).birth.reason
      assert_equal "bce", entity(born: -427).birth.reason
      assert_nil entity(born: -427).birth_year
    end

    test "a precise value wins over an imprecise one, and agreeing duplicates are one year" do
      assert_equal 1828, entity(born: [{year: 1820, precision: 8}, 1828]).birth_year
      assert_equal 1828, entity(born: [1828, {year: 1828, precision: 11}]).birth_year
    end

    test "identifiers are read by kind" do
      subject = entity(identifiers: {openlibrary: ["OL1A", "OL2A"], viaf: ["123"]})

      assert_equal ["OL1A", "OL2A"], subject.identifiers(:openlibrary)
      assert_equal ["123"], subject.identifiers("viaf")
      assert_equal [], subject.identifiers(:isni)
    end

    test "a stored payload with symbol keys reads the same" do
      payload = Distiller.call(wikidata_entity("Q1", label: "X", born: 1900)).deep_symbolize_keys

      assert_equal 1900, Entity.from_payload(payload).birth_year
    end
  end
end
