# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ApplyWikidataTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Test Author Wikidata")
          @lookup = mock("country_lookup")
          @lookup.stubs(:from_wikidata).returns(::Services::Books::CountryLookup::Result.new(countries: [], unmatched: []))
        end

        def entity(**options)
          ::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q42", label: "Test Author Wikidata", **options)))
        end

        def apply(entity, author: @author) = ApplyWikidata.call(author: author, entity: entity, country_lookup: @lookup)

        def held(type) = @author.reload.identifiers.where(identifier_type: type).pluck(:value).sort

        test "stamps the item id and every identifier, one value each, every Open Library key" do
          result = apply(entity(identifiers: {viaf: ["123"], isni: ["0000 0001 2345 6789"], lcnaf: ["n79068416"],
                                              openlibrary: ["OL1A", "OL2A"], goodreads: ["55"], librarything: ["testauthor"]}))

          assert_equal ["Q42"], held("books_author_wikidata_qid")
          assert_equal ["123"], held("books_author_viaf")
          assert_equal ["0000000123456789"], held("books_author_isni")
          assert_equal ["n79068416"], held("books_author_lcnaf")
          assert_equal ["OL1A", "OL2A"], held("books_author_openlibrary_id")
          assert_equal ["55"], held("books_author_goodreads_id")
          assert_equal ["testauthor"], held("books_author_librarything_id")
          assert_equal ["OL1A", "OL2A"], result.data[:facts]["openlibrary_ids"]["added"]
        end

        test "a different identifier of a single-value type is a conflict, not a second value" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "999")

          fact = apply(entity(identifiers: {viaf: ["123"]})).data[:facts]["viaf"]

          assert_equal ["conflict", ["999"]], [fact["reason"], fact["stored"]]
          assert_equal ["999"], held("books_author_viaf")
        end

        test "an identifier another author holds is not stamped, and the pair is flagged as a duplicate" do
          other = ::Books::Author.create!(name: "Someone Else")
          other.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q42")

          result = assert_difference(-> { ::DuplicateCandidate.count }, 1) { apply(entity) }

          assert_equal "held_by_other", result.data[:facts]["wikidata_qid"]["reason"]
          assert_equal [], held("books_author_wikidata_qid")
          assert_equal "external_key_collision", ::DuplicateCandidate.last.source
        end

        test "an author holding a different Wikidata id gets nothing applied" do
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q1")

          result = apply(entity(born: 1900, identifiers: {viaf: ["123"]}))

          assert result.data[:conflict]
          assert_equal ["held_qid_conflict", ["Q1"]], result.data[:facts]["wikidata_qid"].values_at("reason", "held")
          assert_nil @author.reload.birth_year
          assert_equal [], held("books_author_viaf")
        end

        test "a held id Wikidata has merged into the item is not a conflict" do
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q1")

          result = ApplyWikidata.call(author: @author, entity: entity(born: 1900), country_lookup: @lookup, redirected_ids: ["Q1"])

          assert_not result.data[:conflict]
          assert_equal ["Q1", "Q42"], held("books_author_wikidata_qid")
          assert_equal 1900, @author.reload.birth_year
          assert_equal ["Q1"], result.data[:facts]["wikidata_qid"]["redirected_from"]
        end

        test "fills blank years; a disagreeing stored year is a recorded conflict" do
          @author.update!(death_year: 1950)

          facts = apply(entity(born: {year: 1900, precision: 11}, died: 1951)).data[:facts]

          assert_equal [1900, 1950], [@author.reload.birth_year, @author.death_year]
          assert_equal ["filled", "conflict"], [facts["birth_year"]["reason"], facts["death_year"]["reason"]]
          assert_equal 1950, facts["death_year"]["stored"]
        end

        test "a decade-precision, unknown or BCE date is recorded, never applied" do
          assert_equal "imprecise", apply(entity(born: {year: 1900, precision: 8})).data[:facts]["birth_year"]["reason"]
          assert_equal "unknown", apply(entity(born: :unknown)).data[:facts]["birth_year"]["reason"]
          assert_equal "bce", apply(entity(born: -427)).data[:facts]["birth_year"]["reason"]
          assert_nil @author.reload.birth_year
        end

        test "maps gender, fills unspecified, and records a conflict with a stored gender" do
          apply(entity(gender: ["Q1052281"]))
          assert_equal "female", @author.reload.gender

          unspecified = ::Books::Author.create!(name: "Unspecified Gender", gender: :unspecified)
          apply(entity(gender: ["Q6581097"]), author: unspecified)
          assert_equal "male", unspecified.reload.gender

          stored = ::Books::Author.create!(name: "Stored Gender", gender: :female)
          fact = apply(entity(gender: ["Q6581097"]), author: stored).data[:facts]["gender"]
          assert_equal ["conflict", "female"], [fact["reason"], stored.reload.gender]
        end

        test "an unmapped gender is recorded, not applied" do
          fact = apply(entity(gender: ["Q505371"])).data[:facts]["gender"]

          assert_equal "unmapped", fact["reason"]
          assert_nil @author.reload.gender
        end

        test "adds the label, aliases, native names and pseudonyms as alternate names, skipping its own name" do
          apply(entity(aliases: ["T. A. Wikidata", "test author wikidata"], native_names: ["Тест Автор"], pseudonyms: ["Penname"]))

          assert_equal ["T. A. Wikidata", "Тест Автор", "Penname"], @author.reload.alternate_names
        end

        test "keeps each spelling of a name with diacritics as its own alternate name" do
          author = ::Books::Author.create!(name: "Gabriel Garcia Marquez")

          apply(::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q5878", label: "Gabriel García Márquez"))), author: author)

          assert_equal ["Gabriel García Márquez"], author.reload.alternate_names
        end

        test "adds at most 20 alternate names per run" do
          fact = apply(entity(aliases: (1..25).map { |n| "Alias Number #{n}" })).data[:facts]["alternate_names"]

          assert_equal 20, @author.reload.alternate_names.size
          assert_equal 26, fact["offered"]
        end

        test "fills countries through the lookup only when the author has none" do
          russian = ::Books::Country.create!(name: "Russian Test")
          @lookup.stubs(:from_wikidata).with(["Q34266", "Q33946"])
            .returns(::Services::Books::CountryLookup::Result.new(countries: [russian], unmatched: ["Q33946 Czechoslovakia"]))

          fact = apply(entity(citizenships: ["Q34266", "Q33946"])).data[:facts]["countries"]

          assert_equal [russian], @author.reload.countries.to_a
          assert_equal ["filled", ["Q33946 Czechoslovakia"]], [fact["reason"], fact["unmatched"]]
          assert_equal "already_set", apply(entity(citizenships: ["Q30"])).data[:facts]["countries"]["reason"]
        end

        test "never writes the name or the kind" do
          apply(entity(aliases: ["Other Name"]))

          assert_equal ["Test Author Wikidata", "person"], [@author.reload.name, @author.kind]
        end

        test "a second run applies nothing new" do
          applied = entity(born: 1900, identifiers: {openlibrary: ["OL1A"]}, aliases: ["Another"])
          apply(applied)

          result = assert_no_difference(-> { ::Identifier.count }) { apply(applied) }

          assert_empty result.data[:applied]
        end
      end
    end
  end
end
