# frozen_string_literal: true

require "test_helper"

module Wikidata
  class WorkTest < ActiveSupport::TestCase
    def work(id)
      Work.from_payload(WorkDistiller.call(JSON.parse(file_fixture("wikidata/wbgetentities_#{id}.json").read)["entities"][id]))
    end

    test "a novel is a written work and not an edition" do
      novel = work("Q161531")

      assert_predicate novel, :written_work?
      assert_not novel.edition?
      assert_equal ["Q30"], novel.countries
      assert_equal ["Q1860"], novel.languages
      assert_equal [1955], novel.publication_years
      assert_equal ["929"], novel.identifiers["goodreads_book"]
    end

    test "readers return the distilled fields" do
      novel = work("Q161531")

      assert_equal "Q161531", novel.id
      assert_equal "Lolita", novel.label
      assert_equal "1955 novel by Vladimir Nabokov", novel.description
      assert_equal ["Q8253"], novel.genres
      assert_equal ["Q1"], novel.main_subjects
      assert_equal ["Q1297"], novel.narrative_locations
      assert_equal ["Q1"], novel.set_in_periods
      assert_equal ["Q8261"], novel.forms
    end

    test "a film is not a written work" do
      film = Work.from_payload("instance_of" => ["Q11424"])

      assert_not film.written_work?
      assert_not work("Q999002").written_work?
    end

    test "a work whose form is written counts even when its type is not" do
      assert_predicate Work.from_payload("instance_of" => ["Q1"], "forms" => ["Q8261"]), :written_work?
    end

    test "an edition item is an edition and names its work" do
      edition = work("Q999001")

      assert_predicate edition, :edition?
      assert_equal ["Q161531"], edition.edition_of
    end

    test "readers on an empty payload return empty values" do
      empty = Work.from_payload({})

      assert_equal [], empty.authors
      assert_equal({}, empty.identifiers)
      assert_nil empty.enwiki_title
    end
  end
end
