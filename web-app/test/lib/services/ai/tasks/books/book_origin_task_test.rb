require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class BookOriginTaskTest < ActiveSupport::TestCase
          def setup
            @book = books_books(:war_and_peace)
          end

          def build_dossier(authors: nil, wikidata: :default, wikipedia: :default, worldcat: :default, book_facts: nil, real: [], language: "Spanish")
            authors ||= [{"name" => "Gabriel García Márquez", "role" => "author", "kind" => "person", "countries" => ["Colombian"],
                          "birth_year" => 1927, "death_year" => 2014, "place_country" => nil}]
            if wikidata == :default
              wikidata = {"qid" => "Q1", "label" => "One Hundred Years of Solitude", "description" => "novel",
                          "countries" => ["Colombia"], "country_ids" => [1], "country_matches" => ["Colombia"],
                          "languages" => ["Spanish"], "publication_years" => [1967]}
            end
            if wikipedia == :default
              wikipedia = {"title" => "T", "url" => "u", "lead" => "A novel.", "infobox_country" => "Colombia", "infobox_language" => "Spanish"}
            end
            if worldcat == :default
              worldcat = {"publication_places" => ["Buenos Aires", "Madrid"], "earliest_year" => 1967, "cataloging_languages" => ["spa"]}
            end
            Services::Books::Categorize::Dossier.new(
              book: @book, evidence_id: 1,
              record: {"title" => "One Hundred Years of Solitude", "subtitle" => nil, "first_published_year" => 1967,
                       "original_language" => language, "countries" => real, "real_countries" => real, "authors" => authors},
              book_facts: book_facts, wikidata: wikidata, wikipedia: wikipedia, worldcat: worldcat
            )
          end

          def task(dossier: build_dossier, mode: :knowledge)
            BookOriginTask.new(parent: @book, dossier: dossier, mode: mode)
          end

          test "the user prompt carries the record and every evidence section" do
            prompt = task.send(:user_prompt)
            assert_includes prompt, "Book: \"One Hundred Years of Solitude\""
            assert_includes prompt, "Author: Gabriel García Márquez (1927–2014; Colombian)"
            assert_includes prompt, "Original language (our record): Spanish"
            assert_includes prompt, "Wikidata: \"One Hundred Years of Solitude\" (novel); country of origin: Colombia; language: Spanish; published: 1967"
            assert_includes prompt, "Wikipedia infobox: country Colombia; language Spanish"
            assert_includes prompt, "Wikipedia lead: A novel."
            assert_includes prompt, "Library records (WorldCat): published in Buenos Aires, Madrid; earliest edition 1967"
            assert prompt.end_with?("\n\nGive the book's origin as JSON matching the schema.")
          end

          test "a placeholder author is not presented as a person" do
            authors = [{"name" => "Unknown", "role" => "author", "kind" => "placeholder", "countries" => [], "birth_year" => nil, "death_year" => nil, "place_country" => nil}]
            assert_includes task(dossier: build_dossier(authors: authors)).send(:user_prompt),
              "Author: none known (catalogued as \"Unknown\", a placeholder, not a person)"
          end

          test "a place author is presented as an origin signal" do
            authors = [{"name" => "China", "role" => "author", "kind" => "place", "countries" => [], "birth_year" => nil, "death_year" => nil, "place_country" => "Chinese"}]
            assert_includes task(dossier: build_dossier(authors: authors)).send(:user_prompt),
              "Author: catalogued under the place name \"China\" (origin signal: Chinese)"
          end

          test "an editor is named as one and a bare person is just the name" do
            authors = [{"name" => "Ed Itor", "role" => "editor", "kind" => "person", "countries" => ["French"], "birth_year" => 1900, "death_year" => nil, "place_country" => nil},
              {"name" => "Bare Person", "role" => "author", "kind" => "person", "countries" => [], "birth_year" => nil, "death_year" => nil, "place_country" => nil},
              {"name" => "Born Only", "role" => "author", "kind" => "person", "countries" => [], "birth_year" => 1927, "death_year" => nil, "place_country" => nil}]
            prompt = task(dossier: build_dossier(authors: authors)).send(:user_prompt)
            assert_includes prompt, "Editor: Ed Itor\n"
            assert_includes prompt, "Author: Bare Person\n"
            assert_includes prompt, "Author: Born Only (born 1927)\n"
          end

          test "sections the dossier lacks produce no lines" do
            prompt = task(dossier: build_dossier(wikidata: nil, wikipedia: nil, worldcat: nil)).send(:user_prompt)
            refute_includes prompt, "Wikidata:"
            refute_includes prompt, "Wikipedia"
            refute_includes prompt, "WorldCat"
            refute_includes prompt, "Earlier AI facts"
            refute_includes prompt, "Our current origin"
          end

          test "earlier AI facts list only present values" do
            facts = {"recognized" => true, "mode" => "knowledge", "original_language" => "Spanish", "origin_countries" => ["Colombian", "French"], "book_type" => "fiction"}
            assert_includes task(dossier: build_dossier(book_facts: facts)).send(:user_prompt), "Earlier AI facts: original language Spanish; origin Colombian, French"
            only = facts.merge("original_language" => nil)
            assert_includes task(dossier: build_dossier(book_facts: only)).send(:user_prompt), "Earlier AI facts: origin Colombian, French\n"
            assert_includes task(dossier: build_dossier(book_facts: facts.merge("origin_countries" => []))).send(:user_prompt), "Earlier AI facts: original language Spanish\n"
          end

          test "a blank wikidata description drops the parenthetical" do
            wd = {"label" => "X", "description" => "", "countries" => [], "country_ids" => [], "country_matches" => [], "languages" => [], "publication_years" => []}
            assert_includes task(dossier: build_dossier(wikidata: wd)).send(:user_prompt), "Wikidata: \"X\"\n"
          end

          test "the system message keeps the old site's worked examples" do
            assert_includes task.send(:system_message), "\"Lolita\" by Vladimir Nabokov"
            assert_includes task.send(:system_message), "Result: Multiple"
            refute_includes task.send(:system_message), "Use web search"
          end

          test "research mode asks for web search and uses the research role" do
            research = task(mode: :research)
            assert_includes research.send(:system_message), "Use web search"
            assert_equal :research, research.send(:task_role)
          end

          test "knowledge mode uses the standard role and sourced is refused" do
            assert_equal :standard, task.send(:task_role)
            assert_raises(ArgumentError) { task(mode: :sourced) }
          end

          test "the schema has the five fields" do
            keys = BookOriginTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
            assert_equal %w[confidence nationality original_language reason recognized], keys.sort
            assert_equal BookOriginTask::ResponseSchema, task.send(:response_schema)
          end

          test "PROMPT_VERSION is 1" do
            assert_equal 1, BookOriginTask::PROMPT_VERSION
          end
        end
      end
    end
  end
end
