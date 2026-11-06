# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Categorize
      class DossierTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Dossier Test Book", first_published_year: 1900,
            original_language: Language.first)
          @unknown = ::Books::Country.find_or_create_by!(name: "Unknown")
          @book.countries << @unknown
        end

        def person(name, countries: [])
          ::Books::Author.create!(name: name, birth_year: 1800, death_year: 1870).tap do |author|
            countries.each { |c| author.countries << ::Books::Country.find_or_create_by!(name: c) }
          end
        end

        def evidence(facts)
          @book.enrichments.create!(kind: "books.evidence", outcome: :applied, facts: facts)
        end

        test "reads the latest evidence row and the book's record" do
          older = evidence("schema_version" => 2, "wikidata" => {"qid" => "Q1", "countries" => ["France"]})
          newer = evidence("schema_version" => 2, "wikidata" => {"qid" => "Q2", "countries" => ["United States"],
                                                                 "country_matches" => ["American"]})
          assert_operator newer.id, :>, older.id
          dossier = Dossier.build(book: @book)
          assert_equal newer.id, dossier.evidence_id
          assert_equal ["American"], dossier.wikidata["country_matches"]
          assert_equal [], dossier.real_countries
          assert_equal ["Unknown"], dossier.record["countries"]
          assert_equal [], dossier.record["real_countries"]
          assert dossier.external?
        end

        test "a schema 1 evidence row has no country_matches and still builds" do
          evidence("schema_version" => 1, "wikidata" => {"qid" => "Q2", "countries" => ["France"]})
          wikidata = Dossier.build(book: @book).wikidata
          assert_equal [], wikidata["country_matches"]
          assert_equal [], wikidata["country_ids"]
          assert_equal [], wikidata["languages"]
        end

        test "a book with no evidence row has no external section" do
          dossier = Dossier.build(book: @book)
          refute dossier.external?
          assert_nil dossier.evidence_id
          assert_nil dossier.wikidata
          assert_nil dossier.book_facts
        end

        test "wikipedia and worldcat sections are read from the evidence" do
          evidence("wikidata" => nil,
            "wikipedia" => {"title" => "T", "url" => "u", "lead" => "x" * 1500,
                            "infobox" => {"country" => "France", "language" => "French"}},
            "worldcat" => {"publication_places" => ["Paris"], "earliest_year" => 1850, "cataloging_languages" => ["fre"], "records" => 3})
          dossier = Dossier.build(book: @book)
          assert_equal 1000, dossier.wikipedia["lead"].length
          assert_equal "France", dossier.wikipedia["infobox_country"]
          assert_equal "French", dossier.wikipedia["infobox_language"]
          assert_equal({"publication_places" => ["Paris"], "earliest_year" => 1850, "cataloging_languages" => ["fre"]}, dossier.worldcat)
          assert_nil dossier.wikidata
          assert dossier.external?
        end

        test "placeholder and place authors are marked, and only people and places give author countries" do
          ::Books::Country.find_or_create_by!(name: "Chinese")
          {"Unknown" => [:author, 1], "China" => [:author, 2], "Some Editor" => [:editor, 3]}.each do |name, (role, pos)|
            author = (name == "Some Editor") ? person(name, countries: ["British"]) : ::Books::Author.create!(name: name)
            @book.book_authors.create!(author: author, role: role, position: pos)
          end
          dossier = Dossier.build(book: @book)
          assert_equal %w[placeholder place person], dossier.record["authors"].map { it["kind"] }
          assert_equal %w[author author editor], dossier.record["authors"].map { it["role"] }
          assert_equal "Chinese", dossier.record["authors"][1]["place_country"]
          assert_equal ["Chinese"], dossier.author_countries
        end

        test "author countries come from person authors, unique, in author order" do
          @book.book_authors.create!(author: person("Jane Writer", countries: ["British"]), role: :author, position: 1)
          @book.book_authors.create!(author: person("Joe Writer", countries: ["British", "French"]), role: :author, position: 2)
          assert_equal %w[British French], Dossier.build(book: @book).author_countries
        end

        test "author countries tolerate a record with no authors key" do
          dossier = Dossier.new(book: @book, evidence_id: nil, record: {}, book_facts: nil, wikidata: nil, wikipedia: nil, worldcat: nil)
          assert_equal [], dossier.author_countries
        end

        test "real countries drop placeholders" do
          french = ::Books::Country.find_or_create_by!(name: "French")
          @book.countries << french
          dossier = Dossier.build(book: @book)
          assert_equal [french], dossier.real_countries
          assert_equal %w[French], dossier.record["real_countries"]
        end

        test "book_facts comes from the latest usable book_facts row" do
          @book.enrichments.create!(kind: Services::Books::EnrichBook::KIND, outcome: :applied, recognized: true, mode: :knowledge,
            facts: {"origin_countries" => {"value" => ["French"], "confidence" => "high", "applied" => true},
                    "original_language" => {"value" => "French"}, "book_type" => {"value" => "novel"}})
          @book.enrichments.create!(kind: Services::Books::EnrichBook::KIND, outcome: :failed, facts: {})
          facts = Dossier.build(book: @book).book_facts
          assert_equal ["French"], facts["origin_countries"]
          assert_equal "French", facts["original_language"]
          assert_equal "novel", facts["book_type"]
          assert_equal true, facts["recognized"]
          assert_equal "knowledge", facts["mode"]
        end

        test "to_ledger trims the Wikipedia lead" do
          evidence("wikipedia" => {"title" => "T", "lead" => "y" * 1500, "infobox" => {}})
          ledger = Dossier.build(book: @book).to_ledger
          assert_operator ledger.dig("wikipedia", "lead").length, :<=, 500
          assert_equal @book.title, ledger.dig("record", "title")
        end
      end
    end
  end
end
