require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class AuthorFactsTaskTest < ActiveSupport::TestCase
          MATCH = ::Services::Books::Authors::MatchedRecords::Match

          def setup
            @author = books_authors(:tolstoy)
          end

          def records(wikidata: nil, viaf: nil, lead: nil)
            stub(wikidata: wikidata, viaf: viaf, lead: lead)
          end

          def task(mode: :knowledge, **sources)
            AuthorFactsTask.new(parent: @author, records: records(**sources), mode: mode)
          end

          def prompt(**sources) = task(**sources).send(:user_prompt)

          def lead(extract)
            ::Wikipedia::Lead.new(language: "en", page_id: 9, title: "Leo Tolstoy", url: "https://en.wikipedia.org/wiki/Leo_Tolstoy",
              extract: extract, wikibase_item: "Q7243", disambiguation: false)
          end

          test "runs on openai as an analysis chat with json mode and its own schema" do
            subject = task

            assert_equal :openai, subject.send(:provider).provider_key
            assert_equal :analysis, subject.send(:chat_type)
            assert_equal({type: "json_object"}, subject.send(:response_format))
            assert_equal AuthorFactsTask::ResponseSchema, subject.send(:response_schema)
          end

          test "the schema is a class-level json schema with every fact" do
            keys = AuthorFactsTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)

            assert_equal %w[birth_year confidence death_year description gender nationalities recognized], keys.sort
          end

          test "knowledge runs on the standard role and research on the research role" do
            assert_equal [:standard, :research], [task.send(:task_role), task(mode: :research).send(:task_role)]
          end

          test "the prompt names the author, the other names and what we already hold" do
            @author.author_countries.create!(country: books_countries(:french))

            text = prompt

            assert_includes text, "Author: Leo Tolstoy"
            assert_includes text, "Also known as: Lev Tolstoy; Lev Nikolayevich Tolstoy"
            assert_includes text, "Already on record: born 1828; died 1910; nationality French"
          end

          test "the prompt lists our books with their years" do
            assert_includes prompt, "Books by this author in our catalog, best known first:\n- War and Peace (1869)"
          end

          test "a Wikidata match becomes one line of its evidence" do
            evidence = {"description" => "Russian writer", "birth_year" => 1828, "death_year" => 1910,
                        "occupations" => ["novelist", "philosopher"], "citizenships" => ["Russian Empire"],
                        "matching_titles" => ["War and Peace"], "other_titles" => ["Anna Karenina"]}

            text = prompt(wikidata: MATCH.new(source_id: "Q7243", evidence: evidence))

            assert_includes text, "Wikidata: Russian writer | 1828–1910 | occupations: novelist, philosopher | " \
              "citizenship: Russian Empire | notable works: War and Peace; Anna Karenina"
            refute_includes text, "No Wikidata, library or Wikipedia record"
          end

          test "a VIAF match becomes one line of its evidence" do
            evidence = {"headings" => ["Tolstoy, Leo, graf, 1828-1910"], "birth_year" => 1828, "death_year" => 1910,
                        "date_type" => "lived", "nationality" => ["RU"], "occupations" => ["Novelists"],
                        "matching_titles" => ["War and peace"], "other_titles" => [], "agency_count" => 30}

            text = prompt(viaf: MATCH.new(source_id: "27068555", evidence: evidence))

            assert_includes text, "Library authority record (VIAF): headings: Tolstoy, Leo, graf, 1828-1910 | 1828–1910 | " \
              "nationality: RU | occupations: Novelists | works: War and peace | 30 contributing libraries"
          end

          test "a VIAF span that is not a life span is marked as active years" do
            evidence = {"external_title" => "Anna Brenner", "birth_year" => 1920, "death_year" => 1950, "date_type" => "flourished"}

            assert_includes prompt(viaf: MATCH.new(source_id: "1", evidence: evidence)),
              "Library authority record (VIAF): headings: Anna Brenner | active 1920–1950"
          end

          test "the Wikipedia lead is given for facts only, capped" do
            long = "Tolstoy wrote novels. " * 1_000

            text = prompt(wikidata: MATCH.new(source_id: "Q7243", evidence: {}), lead: lead(long))

            assert_includes text, "Wikipedia lead, for facts only; do not reuse its wording:\nTolstoy wrote novels."
            assert_includes text, long.strip.first(AuthorFactsTask::LEAD_LIMIT)
            refute_includes text, long.strip.first(AuthorFactsTask::LEAD_LIMIT + 1)
          end

          test "with nothing matched the prompt says so and has no source lines" do
            text = prompt

            assert_includes text, "No Wikidata, library or Wikipedia record was matched to this author."
            refute_includes text, "Wikidata:"
            refute_includes text, "Wikipedia lead"
          end

          test "the system message carries the author description rules" do
            message = task.send(:system_message)

            assert_includes message, "at most 110 words"
            assert_includes message, "as few as 20 words"
            assert_includes message, "Never repeat a point to fill space"
            refute_includes message, "60 to 110"
            assert_includes message, "Never mention your sources"
            assert_includes message, "Do not open with the author's name"
            assert_includes message, "At most one major prize"
            assert_includes message, "never a death year"
            assert_includes message, "never reuse its phrases"
            assert_includes message, "a year before the Common Era is reported as null"
          end

          test "research mode tells the model to verify with web search" do
            refute_includes task.send(:system_message), "web search"
            assert_includes task(mode: :research).send(:system_message), "web search"
          end

          test "BCE years read as BCE in the author's facts and book list" do
            author = ::Books::Author.create!(name: "Euripides", birth_year: -480, death_year: -406)
            author.book_authors.create!(book: ::Books::Book.create!(title: "Medea", first_published_year: -431), position: 1)

            text = AuthorFactsTask.new(parent: author, records: records, mode: :knowledge).send(:user_prompt)

            assert_includes text, "Already on record: born 480 BCE; died 406 BCE"
            assert_includes text, "- Medea (431 BCE)"
          end
        end
      end
    end
  end
end
