require "test_helper"

module Services
  module Books
    module Origin
      class ShortcutTest < ActiveSupport::TestCase
        def author(name, countries, kind: "person", place_country: nil)
          {"name" => name, "role" => "author", "kind" => kind, "countries" => countries, "birth_year" => nil, "death_year" => nil, "place_country" => place_country}
        end

        def wd(matches: ["French"], ids: [1], countries: matches, languages: [])
          {"qid" => "Q1", "label" => "L", "description" => nil, "countries" => countries, "country_ids" => ids,
           "country_matches" => matches, "languages" => languages, "publication_years" => []}
        end

        def dossier(authors: [author("A", ["French"])], wikidata: wd, language: "French", facts: nil)
          Categorize::Dossier.new(book: nil, evidence_id: 1,
            record: {"original_language" => language, "authors" => authors, "real_countries" => []},
            book_facts: facts, wikidata: wikidata, wikipedia: nil, worldcat: nil)
        end

        test "returns the country when wikidata, author and language agree" do
          assert_equal books_countries(:french), Shortcut.call(dossier)
        end

        test "nil when the author is from elsewhere" do
          assert_nil Shortcut.call(dossier(authors: [author("A", ["Belgian"])]))
        end

        test "nil when the language does not belong to the country" do
          assert_nil Shortcut.call(dossier(language: "English"))
        end

        test "nil when wikidata lists two countries" do
          assert_nil Shortcut.call(dossier(wikidata: wd(matches: ["French", "Belgian"], ids: [1, 2])))
        end

        test "nil without a wikidata section or any language" do
          assert_nil Shortcut.call(dossier(wikidata: nil))
          assert_nil Shortcut.call(dossier(language: nil))
        end

        test "a schema-1 row falls back to the single countries entry" do
          assert_equal books_countries(:french), Shortcut.call(dossier(wikidata: wd(ids: [], countries: ["France"])))
          assert_nil Shortcut.call(dossier(wikidata: wd(ids: [], countries: ["France", "Spain"])))
        end

        test "the language falls back to wikidata's single language, then book facts" do
          assert_equal books_countries(:french), Shortcut.call(dossier(language: nil, wikidata: wd(languages: ["French"])))
          assert_nil Shortcut.call(dossier(language: nil, wikidata: wd(languages: ["French", "English"])))
          assert_equal books_countries(:french), Shortcut.call(dossier(language: nil, facts: {"original_language" => "French"}))
        end

        test "a place author with a matching wikidata country returns it" do
          ::Books::Country.find_or_create_by!(name: "Chinese")
          authors = [author("China", [], kind: "place", place_country: "Chinese")]
          result = Shortcut.call(dossier(authors: authors, wikidata: wd(matches: ["Chinese"]), language: "Classical Chinese"))
          assert_equal "Chinese", result&.name
        end

        test "a record without an authors key, or no record, returns nil without raising" do
          no_authors = Categorize::Dossier.new(book: nil, evidence_id: 1, record: {"original_language" => "French"},
            book_facts: nil, wikidata: wd, wikipedia: nil, worldcat: nil)
          assert_nil Shortcut.call(no_authors)
          no_record = Categorize::Dossier.new(book: nil, evidence_id: 1, record: nil,
            book_facts: nil, wikidata: wd, wikipedia: nil, worldcat: nil)
          assert_nil Shortcut.call(no_record)
        end
      end
    end
  end
end
