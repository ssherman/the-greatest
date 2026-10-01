# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ApplyViafTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Stacy Willingham")
          @lookup = mock("country_lookup")
          @lookup.stubs(:from_iso).returns(::Services::Books::CountryLookup::Result.new(countries: [], unmatched: []))
        end

        def apply(person, author: @author) = ApplyViaf.call(author: author, person: person, country_lookup: @lookup)

        def held(type) = @author.reload.identifiers.where(identifier_type: type).pluck(:value).sort

        test "stamps VIAF, ISNI, LC and the cluster's Wikidata id, and reports the new Wikidata id" do
          result = apply(viaf_person("5391", isni: "0000000507233592", lc: "n2021040535", wikidata: "Q115493575"))

          assert_equal [["5391"], ["0000000507233592"], ["n2021040535"], ["Q115493575"]],
            %w[books_author_viaf books_author_isni books_author_lcnaf books_author_wikidata_qid].map { |type| held(type) }
          assert_equal "Q115493575", result.data[:wikidata_qid]
        end

        test "a malformed Wikidata id is not stamped" do
          result = apply(viaf_person("1", wikidata: "Q7243x"))

          assert_empty held("books_author_wikidata_qid")
          assert_nil result.data[:wikidata_qid]
        end

        test "a Wikidata id already held, held by another author, or conflicting is not reported as new" do
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q1")
          assert_nil apply(viaf_person("1", wikidata: "Q1")).data[:wikidata_qid]
          assert_nil apply(viaf_person("1", wikidata: "Q2")).data[:wikidata_qid]

          other = ::Books::Author.create!(name: "Other Author")
          other.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q3")
          fresh = ::Books::Author.create!(name: "Fresh Author")
          result = assert_difference(-> { ::DuplicateCandidate.count }, 1) { apply(viaf_person("2", wikidata: "Q3"), author: fresh) }

          assert_nil result.data[:wikidata_qid]
          assert_equal "external_key_collision", ::DuplicateCandidate.last.source
        end

        test "an author holding a different VIAF id gets nothing applied" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "999")

          result = apply(viaf_person("5391", born: "1991", isni: "0000000507233592"))

          assert result.data[:conflict]
          assert_equal "held_viaf_conflict", result.data[:facts]["viaf"]["reason"]
          assert_nil @author.reload.birth_year
          assert_empty held("books_author_isni")
        end

        test "fills life years; a living person's 0 death date is no year" do
          apply(viaf_person("1", born: "1991-01-30", died: 0))

          assert_equal [1991, nil], [@author.reload.birth_year, @author.death_year]
        end

        # A cluster can merge two people (Sarah Morgan's carried another Sarah
        # Morgan's 1948–2013); the Wikidata run that follows is the better source.
        test "a cluster that names a Wikidata item leaves the years to Wikidata" do
          facts = apply(viaf_person("1", born: "1948-05-17", died: "2013-12-00", wikidata: "Q57394720")).data[:facts]

          assert_equal ["wikidata_linked", "wikidata_linked"], [facts["birth_year"]["reason"], facts["death_year"]["reason"]]
          assert_equal [nil, nil], [@author.reload.birth_year, @author.death_year]
        end

        test "a death year contradicted by the author's own later books is recorded, not applied" do
          @author.book_authors.create!(book: ::Books::Book.create!(title: "Beach House Summer", first_published_year: 2021), position: 1)

          facts = apply(viaf_person("1", born: "1948", died: "2013")).data[:facts]

          assert_equal ["before_books", 2021], facts["death_year"].values_at("reason", "latest_book")
          assert_equal [1948, nil], [@author.reload.birth_year, @author.death_year]
        end

        test "a flourished span, a BCE year or a disagreeing year is recorded, never applied" do
          facts = apply(viaf_person("1", born: "1850", died: "1870", date_type: "flourished")).data[:facts]
          assert_equal ["not_life_dates", "not_life_dates"], [facts["birth_year"]["reason"], facts["death_year"]["reason"]]

          ancient = ::Books::Author.create!(name: "Ancient Author")
          assert_equal "bce", apply(viaf_person("2", born: "-384"), author: ancient).data[:facts]["birth_year"]["reason"]

          dated = ::Books::Author.create!(name: "Dated Author", birth_year: 1900)
          assert_equal "conflict", apply(viaf_person("3", born: "1950"), author: dated).data[:facts]["birth_year"]["reason"]
          assert_nil @author.reload.birth_year
        end

        test "maps gender codes; unspecified is recorded, not applied" do
          apply(viaf_person("1", gender: "a"))
          assert_equal "female", @author.reload.gender

          other = ::Books::Author.create!(name: "Unknown Gender")
          fact = apply(viaf_person("2", gender: "u"), author: other).data[:facts]["gender"]
          assert_equal ["null", nil], [fact["reason"], other.reload.gender]
        end

        test "fills countries from the two-letter nationality codes only" do
          american = ::Books::Country.create!(name: "American Test")
          @lookup.expects(:from_iso).with(["US"]).returns(::Services::Books::CountryLookup::Result.new(countries: [american], unmatched: []))

          apply(viaf_person("1", nationality: ["US", "us", "Stany Zjednoczone"]))

          assert_equal [american], @author.reload.countries.to_a
        end

        test "adds main headings in natural order, Latin script only, never the Wikidata heading or a reordering" do
          author = ::Books::Author.create!(name: "Leo Tolstoy")
          apply(viaf_person("1", headings: [
            "Tolstoy, Leo", "Tolstoï, Léon", "Tolstoi, Lev Nikolaevich, graf", "Толстой, Лев", "Tolstoy Leo",
            {"source" => "WKP", "name" => "Tolstoy, Russian writer", "surname_first" => true}
          ]), author: author)

          assert_equal ["Léon Tolstoï", "Lev Nikolaevich Tolstoi"], author.reload.alternate_names
        end

        test "a heading that only reorders our name is skipped" do
          author = ::Books::Author.create!(name: "Mo Yan")

          apply(viaf_person("1", headings: ["Mo, Yan"]), author: author)

          assert_empty Array(author.reload.alternate_names)
        end

        test "a forename heading, or one of unknown entry, is never inverted into an alternate name" do
          author = ::Books::Author.create!(name: "Hildegard von Bingen")
          apply(viaf_person("1", headings: [
            {"source" => "LC", "name" => "Hildegard, of Bingen, Saint", "surname_first" => false},
            {"source" => "BNF", "name" => "Hildegard, Saint", "surname_first" => nil}
          ]), author: author)

          assert_empty Array(author.reload.alternate_names)
        end

        # Letters, not digits: natural() strips digits as dates.
        test "adds at most 10 alternate names" do
          apply(viaf_person("1", headings: ("A".."L").map { |letter| "Surname#{letter}, Given" }))

          assert_equal 10, @author.reload.alternate_names.size
        end

        test "never writes the name or the kind, and a second run applies nothing new" do
          person = viaf_person("1", born: "1991", gender: "a", isni: "0000000507233592", headings: ["Willingham, Stacy J."])
          apply(person)

          result = assert_no_difference(-> { ::Identifier.count }) { apply(person) }

          assert_empty result.data[:applied]
          assert_equal ["Stacy Willingham", "person"], [@author.reload.name, @author.kind]
        end
      end
    end
  end
end
