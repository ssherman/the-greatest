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
          assert_equal({"publication_places" => ["Paris"], "earliest_year" => 1850, "cataloging_languages" => ["fre"]},
            dossier.worldcat.slice("publication_places", "earliest_year", "cataloging_languages"))
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

        def facts_row(mode:, recognized:, outcome: :applied)
          @book.enrichments.create!(kind: Services::Books::EnrichBook::KIND, outcome: outcome, recognized: recognized, mode: mode,
            citations: (1..7).map { "https://example.org/#{it}" },
            facts: {"origin_countries" => {"value" => ["Peruvian"]}, "description" => {"value" => "d" * 700}})
        end

        test "book_facts carries the first five citations and a description cut to 600 characters" do
          facts_row(mode: :research, recognized: true)
          facts = Dossier.build(book: @book).book_facts
          assert_equal (1..5).map { "https://example.org/#{it}" }, facts["citations"]
          assert_equal 600, facts["description"].length
        end

        test "research_backed? needs a recognized research-mode book_facts row" do
          assert_not Dossier.build(book: @book).research_backed?
          facts_row(mode: :knowledge, recognized: true)
          assert_not Dossier.build(book: @book).research_backed?
          facts_row(mode: :research, recognized: false, outcome: :unrecognized)
          assert_not Dossier.build(book: @book).research_backed?
          facts_row(mode: :research, recognized: true)
          dossier = Dossier.build(book: @book)
          assert dossier.research_backed?
          assert_not dossier.external?
        end

        test "to_ledger trims the Wikipedia lead" do
          evidence("wikipedia" => {"title" => "T", "lead" => "y" * 1500, "infobox" => {}})
          ledger = Dossier.build(book: @book).to_ledger
          assert_operator ledger.dig("wikipedia", "lead").length, :<=, 500
          assert_equal @book.title, ledger.dig("record", "title")
        end

        test "wikidata carries the category lists" do
          evidence("wikidata" => {"qid" => "Q1", "genres" => ["novel"], "main_subjects" => ["war"],
                                  "narrative_locations" => ["Paris"], "set_in_periods" => ["1900s"], "forms" => ["prose"]})
          wikidata = Dossier.build(book: @book).wikidata
          assert_equal ["novel"], wikidata["genres"]
          assert_equal ["war"], wikidata["main_subjects"]
          assert_equal ["Paris"], wikidata["narrative_locations"]
          assert_equal ["1900s"], wikidata["set_in_periods"]
          assert_equal ["prose"], wikidata["forms"]
        end

        test "wikipedia carries the plot cut to 2000 and the infobox genre, subject and set_in" do
          evidence("wikipedia" => {"title" => "T", "plot" => "p" * 2500,
                                   "infobox" => {"genre" => "Novel", "subject" => "War", "set_in" => "Paris"}})
          wikipedia = Dossier.build(book: @book).wikipedia
          assert_equal 2000, wikipedia["plot"].length
          assert_equal "Novel", wikipedia["infobox_genre"]
          assert_equal "War", wikipedia["infobox_subject"]
          assert_equal "Paris", wikipedia["infobox_set_in"]
        end

        test "worldcat carries mapped genres, the first 25 subject headings and the summary" do
          subjects = (1..30).to_h { ["Heading #{it}", it] }
          evidence("worldcat" => {"publication_places" => ["Paris"], "mapped_genres" => {"Fiction" => 3},
                                  "subjects" => subjects, "summary" => "A summary"})
          worldcat = Dossier.build(book: @book).worldcat
          assert_equal({"Fiction" => 3}, worldcat["mapped_genres"])
          assert_equal subjects.keys.first(25), worldcat["subjects"]
          assert_equal "A summary", worldcat["summary"]
        end

        test "worldcat tolerates stored sections without the new keys" do
          evidence("worldcat" => {"publication_places" => ["Paris"]})
          worldcat = Dossier.build(book: @book).worldcat
          assert_equal [], worldcat["subjects"]
          assert_equal({}, worldcat["mapped_genres"])
          assert_nil worldcat["summary"]
        end

        test "goodreads genres come from the latest found page, capped at 15" do
          @book.identifiers.create!(identifier_type: :books_work_goodreads_id, value: "101")
          @book.identifiers.create!(identifier_type: :books_work_goodreads_id, value: "102")
          ::Books::GoodreadsPage.create!(goodreads_book_id: 101, outcome: :found, fetched_at: 2.days.ago, genres: %w[Old])
          ::Books::GoodreadsPage.create!(goodreads_book_id: 102, outcome: :found, fetched_at: 1.day.ago,
            genres: (1..20).map { "Genre #{it}" })
          dossier = Dossier.build(book: @book)
          assert_equal({"genres" => (1..15).map { "Genre #{it}" }}, dossier.goodreads)
          assert_not dossier.external?
        end

        test "goodreads is nil without a found page" do
          assert_nil Dossier.build(book: @book).goodreads
          @book.identifiers.create!(identifier_type: :books_work_goodreads_id, value: "103")
          ::Books::GoodreadsPage.create!(goodreads_book_id: 103, outcome: :blocked, fetched_at: Time.current, genres: %w[X])
          assert_nil Dossier.build(book: @book).goodreads
        end

        test "Dossier.new works without goodreads" do
          dossier = Dossier.new(book: @book, evidence_id: nil, record: {}, book_facts: nil, wikidata: nil, wikipedia: nil, worldcat: nil)
          assert_nil dossier.goodreads
        end

        test "the record carries the description cut to 1000 and the direct active category links" do
          @book.descriptions.create!(kind: "summary", locale: "en", source: "ai_generated", content: "d" * 1200)
          country = ::Books::Category.create!(name: "Dossier Country", category_type: :location)
          city = ::Books::Category.create!(name: "Dossier City", category_type: :location, parent: country)
          novel = ::Books::Category.create!(name: "Dossier Novel", category_type: :genre)
          war = ::Books::Category.create!(name: "Dossier War", category_type: :subject)
          gone = ::Books::Category.create!(name: "Dossier Gone", category_type: :subject, deleted: true)
          inherited = ::Books::Category.create!(name: "Dossier Inherited", category_type: :genre)
          [[city, :admin], [novel, :admin], [war, :legacy], [gone, :admin]].each do |category, source|
            ::CategoryItem.create!(category: category, item: @book, source: source)
          end
          ::CategoryItem.create!(category: inherited, item: @book, source: :inherited)
          record = Dossier.build(book: @book).record
          assert_equal 1000, record["description"].length
          assert_equal [
            {"id" => novel.id, "name" => "Dossier Novel", "type" => "genre", "source" => "admin", "ancestors" => []},
            {"id" => city.id, "name" => "Dossier City", "type" => "location", "source" => "admin", "ancestors" => ["Dossier Country"]},
            {"id" => war.id, "name" => "Dossier War", "type" => "subject", "source" => "legacy", "ancestors" => []}
          ], record["categories"]
        end

        test "the record has no description when the book has none" do
          assert_nil Dossier.build(book: @book).record["description"]
          assert_equal [], Dossier.build(book: @book).record["categories"]
        end

        test "to_ledger adds goodreads, trims plot, subjects and a long description" do
          evidence("wikipedia" => {"title" => "T", "plot" => "p" * 1500},
            "worldcat" => {"subjects" => (1..30).to_h { ["H#{it}", 1] }})
          @book.descriptions.create!(kind: "summary", locale: "en", source: "ai_generated", content: "d" * 400)
          @book.identifiers.create!(identifier_type: :books_work_goodreads_id, value: "104")
          ::Books::GoodreadsPage.create!(goodreads_book_id: 104, outcome: :found, fetched_at: Time.current, genres: %w[Novel])
          ledger = Dossier.build(book: @book).to_ledger
          assert_equal({"genres" => %w[Novel]}, ledger["goodreads"])
          assert_equal 500, ledger.dig("wikipedia", "plot").length
          assert_equal 15, ledger.dig("worldcat", "subjects").length
          assert_nil ledger.dig("record", "description")
        end

        test "to_ledger trims the worldcat summary to 300 characters" do
          evidence("worldcat" => {"subjects" => {"H" => 1}, "summary" => "s" * 900})
          assert_equal 300, Dossier.build(book: @book).to_ledger.dig("worldcat", "summary").length
        end

        test "to_ledger keeps a short description" do
          @book.descriptions.create!(kind: "summary", locale: "en", source: "ai_generated", content: "short")
          assert_equal "short", Dossier.build(book: @book).to_ledger.dig("record", "description")
        end
      end
    end
  end
end
