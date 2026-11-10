require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class BookCategoriesTaskTest < ActiveSupport::TestCase
          def setup
            @book = books_books(:war_and_peace)
            @fiction = categories(:books_fiction_genre)
            @novels = categories(:books_novels_genre)
            @novels.update!(description: "Long prose narratives")
            @childrens = ::Books::Category.create!(name: "Children's", category_type: "audience", description: "Written for children")
          end

          def build_dossier(book_facts: nil, wikidata: :default, wikipedia: :default, worldcat: :default, goodreads: :default, categories: :default)
            if wikidata == :default
              wikidata = {"qid" => "Q1", "label" => "War and Peace", "description" => "novel", "genres" => ["historical novel"],
                          "main_subjects" => ["Napoleonic Wars"], "narrative_locations" => ["Moscow"], "set_in_periods" => [], "forms" => []}
            end
            if wikipedia == :default
              wikipedia = {"title" => "T", "url" => "u", "lead" => "A long novel.", "plot" => "Pierre wanders.", "infobox_genre" => "Historical fiction",
                           "infobox_subject" => nil, "infobox_set_in" => "Russia", "infobox_country" => nil, "infobox_language" => nil}
            end
            if worldcat == :default
              worldcat = {"mapped_genres" => {"genre:Historical Fiction" => 3, "genre:Classics" => 5}, "subjects" => ["Napoleonic Wars, 1800-1815"],
                          "summary" => "An epic."}
            end
            goodreads = {"genres" => ["Classics", "Russia"]} if goodreads == :default
            if categories == :default
              categories = [{"id" => 1, "name" => "Classics", "type" => "genre", "source" => "legacy", "ancestors" => []},
                {"id" => 2, "name" => "Paris", "type" => "location", "source" => "goodreads", "ancestors" => ["France"]}]
            end
            Services::Books::Categorize::Dossier.new(
              book: @book, evidence_id: 1,
              record: {"title" => "War and Peace", "subtitle" => nil, "first_published_year" => 1869, "original_language" => "Russian",
                       "description" => "Our description.", "categories" => categories, "countries" => [], "real_countries" => [],
                       "authors" => [{"name" => "Leo Tolstoy", "role" => "author"}]},
              book_facts: book_facts, wikidata: wikidata, wikipedia: wikipedia, worldcat: worldcat, goodreads: goodreads
            )
          end

          def task(dossier: build_dossier, mode: :knowledge)
            BookCategoriesTask.new(parent: @book, dossier: dossier, vocabulary: [@fiction, @novels, @childrens], mode: mode)
          end

          test "the system message lists vocabulary ids with descriptions and leaves out Fiction" do
            message = task.send(:system_message)
            assert_includes message, "#{@novels.id}: Novels — Long prose narratives"
            assert_includes message, "#{@childrens.id}: Children's — Written for children"
            refute_includes message, "#{@fiction.id}: Fiction"
            assert_operator message.index("Genres (id"), :<, message.index("Audiences (id")
          end

          test "the system message states the spec rules" do
            message = task.send(:system_message)
            assert_match(/at most 5/, message)
            assert_match(/there is no adult audience/, message)
            assert_match(/at most 8/, message)
            assert_match(/identity, love/, message)
            assert_match(/most specific place/, message)
            assert_match(/"real" or "fictional"/, message)
            assert_match(/recognized/, message)
          end

          test "the user prompt renders every dossier section" do
            prompt = task.send(:user_prompt)
            assert_includes prompt, "Book: \"War and Peace\""
            assert_includes prompt, "Author: Leo Tolstoy"
            assert_includes prompt, "Categories the book holds now (source in brackets):"
            assert_includes prompt, "- genre: Classics [legacy]"
            assert_includes prompt, "- location: Paris (under France) [goodreads]"
            assert_includes prompt, "Wikidata: \"War and Peace\" (novel)"
            assert_includes prompt, "Wikidata genre: historical novel"
            assert_includes prompt, "Wikidata main subject: Napoleonic Wars"
            assert_includes prompt, "Wikipedia lead: A long novel."
            assert_includes prompt, "Wikipedia infobox: genre Historical fiction; set in Russia"
            assert_includes prompt, "Wikipedia plot: Pierre wanders."
            assert_includes prompt, "mapped genres: Classics (5), Historical Fiction (3)"
            assert_includes prompt, "subject headings: Napoleonic Wars, 1800-1815"
            assert_includes prompt, "summary: An epic."
            assert_includes prompt, "Goodreads shelves: Classics, Russia"
            assert prompt.end_with?("Give the book's categories as JSON matching the schema.")
          end

          test "sections the dossier lacks are omitted" do
            prompt = task(dossier: build_dossier(wikidata: nil, wikipedia: nil, worldcat: nil, goodreads: nil, categories: [])).send(:user_prompt)
            refute_includes prompt, "Wikidata"
            refute_includes prompt, "Wikipedia"
            refute_includes prompt, "WorldCat"
            refute_includes prompt, "Goodreads"
            refute_includes prompt, "Categories the book holds now"
          end

          test "earlier AI facts and web-verified facts are told apart" do
            facts = {"recognized" => true, "mode" => "knowledge", "book_type" => "fiction", "original_language" => "Russian"}
            assert_includes task(dossier: build_dossier(book_facts: facts)).send(:user_prompt), "Earlier AI facts: type fiction; original language Russian"
            verified = facts.merge("mode" => "research", "description" => "A novel.")
            prompt = task(dossier: build_dossier(book_facts: verified)).send(:user_prompt)
            assert_includes prompt, "Web-verified facts (from a web search for this book): type fiction"
            assert_includes prompt, "Description: A novel."
          end

          test "research mode adds the web search instruction and the research role" do
            refute_includes task.send(:system_message), "Use web search"
            research = task(mode: :research)
            assert_includes research.send(:system_message), "Use web search"
            assert_equal :research, research.send(:task_role)
          end

          test "knowledge mode is the standard role and sourced raises" do
            assert_equal :standard, task.send(:task_role)
            assert_raises(ArgumentError) { task(mode: :sourced) }
          end

          test "the schema carries every output" do
            keys = BookCategoriesTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
            assert_equal %w[audience book_type confidence genres locations recognized subjects unlisted_genres], keys.sort
            assert_equal BookCategoriesTask::ResponseSchema, task.send(:response_schema)
          end

          test "PROMPT_VERSION is 1" do
            assert_equal 1, BookCategoriesTask::PROMPT_VERSION
          end
        end
      end
    end
  end
end
