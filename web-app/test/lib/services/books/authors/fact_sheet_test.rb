# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class FactSheetTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Fact Sheet Author")
          @sheet = FactSheet.new(@author)
        end

        def lookup(countries, unmatched = []) = ::Services::Books::CountryLookup::Result.new(countries: countries, unmatched: unmatched)

        test "a death year more than two years before one of the author's own books is recorded, not applied" do
          @author.book_authors.create!(book: ::Books::Book.create!(title: "Later Book", first_published_year: 2021), position: 1)

          @sheet.death_year(2013)

          assert_equal ["before_books", false, 2021], @sheet.facts["death_year"].values_at("reason", "applied", "latest_book")
          assert_nil @author.death_year
        end

        test "a death year within two years of the author's last book, or with no books, is filled as usual" do
          @author.book_authors.create!(book: ::Books::Book.create!(title: "Posthumous Book", first_published_year: 2021), position: 1)
          @sheet.death_year(2019)
          assert_equal [2019, "filled"], [@author.death_year, @sheet.facts["death_year"]["reason"]]

          bookless = ::Books::Author.create!(name: "Bookless Author")
          sheet = FactSheet.new(bookless)
          sheet.death_year(1900)
          assert_equal 1900, bookless.death_year
        end

        test "records one fact per field, extras stringified, and lists the applied ones" do
          @sheet.record("birth_year", 1900, applied: true, reason: "filled", source: {kind: "test"})
          @sheet.record("gender", nil, applied: false, reason: "null")

          assert_equal({"value" => 1900, "applied" => true, "reason" => "filled", "source" => {"kind" => "test"}}, @sheet.facts["birth_year"])
          assert_equal ["birth_year"], @sheet.applied
        end

        test "stamps a new identifier and reports one already held" do
          assert_equal "filled", @sheet.stamp("books_author_viaf", "123")
          @author.save!

          assert_equal "already_set", @sheet.stamp("books_author_viaf", "123")
          assert_equal ["123"], @author.reload.identifiers.where(identifier_type: "books_author_viaf").pluck(:value)
        end

        test "never stamps an identifier another author holds, and flags the pair" do
          other = ::Books::Author.create!(name: "Other Holder")
          other.identifiers.create!(identifier_type: "books_author_viaf", value: "123")
          ::Services::DuplicateCandidates::Flag.expects(:call).with(
            item_type: "Books::Author", ids: [@author.id, other.id], source: :external_key_collision,
            evidence: {reason: "VIAF 123 is held by another author", identifiers: [{"type" => "books_author_viaf", "value" => "123"}]},
            match_decision: nil
          )

          assert_equal "held_by_other", @sheet.stamp("books_author_viaf", "123")
          @sheet.flag_collisions(reason: "VIAF 123 is held by another author", decision: nil)
          @author.save!

          assert_empty @author.reload.identifiers
        end

        test "a single-value identifier: blank is null, a different stored value is a conflict" do
          @sheet.single_identifier("isni", "books_author_isni", nil)
          assert_equal "null", @sheet.facts["isni"]["reason"]

          @author.identifiers.create!(identifier_type: "books_author_isni", value: "0000000100000001")
          @sheet.single_identifier("isni", "books_author_isni", "0000000100000002")

          assert_equal ["conflict", ["0000000100000001"]], @sheet.facts["isni"].values_at("reason", "stored")
        end

        test "fills a blank year, keeps an equal one, records a disagreeing one" do
          @author.death_year = 1950
          @sheet.year("birth_year", 1900)
          @sheet.year("death_year", 1951)

          assert_equal [1900, "filled"], [@author.birth_year, @sheet.facts["birth_year"]["reason"]]
          assert_equal [1950, "conflict", 1950], [@author.death_year, *@sheet.facts["death_year"].values_at("reason", "stored")]

          @sheet.year("birth_year", 1900)
          assert_equal "already_set", @sheet.facts["birth_year"]["reason"]
        end

        test "fills gender over a blank or unspecified one, records its source, and never overwrites" do
          @author.gender = :unspecified
          @sheet.gender("female", viaf: "a")
          assert_equal ["female", "filled", "a"], [@author.gender, *@sheet.facts["gender"].values_at("reason", "viaf")]

          @sheet.gender("male", viaf: "b")
          assert_equal ["female", "conflict", "female"], [@author.gender, *@sheet.facts["gender"].values_at("reason", "stored")]
        end

        test "adds new alternate names up to the cap, in stored form, skipping the author's own" do
          @sheet.alternate_names(["fact sheet author", "F. S. Author", "Flannery O’Connor", "Third Name"], cap: 2)

          assert_equal ["F. S. Author", "Flannery O'Connor"], @author.alternate_names
          assert_equal [true, "filled", 4], @sheet.facts["alternate_names"].values_at("applied", "reason", "offered")
        end

        test "no alternate names offered is null; nothing new is already_set" do
          @sheet.alternate_names(["", nil], cap: 10)
          assert_equal "null", @sheet.facts["alternate_names"]["reason"]

          @sheet.alternate_names(["Fact Sheet Author"], cap: 10)
          assert_equal "already_set", @sheet.facts["alternate_names"]["reason"]
        end

        test "fills countries through the lookup, recording what did not match and the source" do
          country = ::Books::Country.create!(name: "Fact Sheet Country")

          @sheet.countries(["FS", "XX"], viaf: ["FS", "XX"]) { |values| lookup([country], values - ["FS"]) }
          @author.save!

          assert_equal [country], @author.reload.countries.to_a
          assert_equal [["Fact Sheet Country"], ["XX"], ["FS", "XX"]], @sheet.facts["countries"].values_at("value", "unmatched", "viaf")
        end

        test "an author with countries is already_set, and the lookup never runs" do
          @author.author_countries.create!(country: ::Books::Country.create!(name: "Held Country"))

          @sheet.countries(["FS"]) { flunk "the lookup must not run" }

          assert_equal "already_set", @sheet.facts["countries"]["reason"]
        end

        test "no values is null, and a lookup matching nothing is no_match" do
          @sheet.countries([]) { flunk "the lookup must not run" }
          assert_equal "null", @sheet.facts["countries"]["reason"]

          @sheet.countries(["ZZ"]) { lookup([], ["ZZ"]) }
          assert_equal ["no_match", ["ZZ"]], @sheet.facts["countries"].values_at("reason", "unmatched")
        end

        def reject_for(author, finder, key)
          ::MatchDecision.create!(finder: finder, subject: author, outcome: :matched, confidence: :high, decided_by: :rule,
            verdict: :rejected, candidates: [{"external_key" => key}], selected_index: 1)
        end

        test "an id of a record rejected for this author is never stamped" do
          reject_for(@author, ResolveViaf.name, "5391")

          @sheet.single_identifier("viaf", "books_author_viaf", "5391")

          assert_equal ["rejected", false], @sheet.facts["viaf"].values_at("reason", "applied")
          assert_not @author.identifiers.exists?(identifier_type: "books_author_viaf")
        end

        test "an id a rejected Wikidata decision's ledger named as redirected_from is never stamped either" do
          rejected = reject_for(@author, ResolveWikidata.name, "Q10")
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, provider: "wikidata", outcome: :applied,
            match_decision: rejected,
            facts: {"wikidata_qid" => {"value" => "Q10", "applied" => true, "reason" => "filled", "redirected_from" => ["Q9"]}})

          @sheet.single_identifier("wikidata_qid", "books_author_wikidata_qid", "Q9")

          assert_equal ["rejected", false], @sheet.facts["wikidata_qid"].values_at("reason", "applied")
          assert_not @author.identifiers.exists?(identifier_type: "books_author_wikidata_qid")
        end

        test "a record rejected for another author does not stop the stamp here" do
          reject_for(::Books::Author.create!(name: "Another Author"), ResolveWikidata.name, "Q1")

          @sheet.single_identifier("wikidata_qid", "books_author_wikidata_qid", "Q1")
          @author.save!

          assert_equal "filled", @sheet.facts["wikidata_qid"]["reason"]
          assert @author.identifiers.exists?(identifier_type: "books_author_wikidata_qid", value: "Q1")
        end

        test "a filled countries fact records the country ids, for a reject to remove" do
          country = ::Books::Country.create!(name: "Fact Sheet Country")

          @sheet.countries(["FS"]) { lookup([country]) }

          assert_equal [country.id], @sheet.facts["countries"]["country_ids"]
        end
      end
    end
  end
end
