require "test_helper"

module Services
  module Books
    module QueueTypes
      class CategoriesTest < ActiveSupport::TestCase
        Type = Services::Books::QueueTypes::Categories

        setup do
          Services::Ai::Tasks::Books::CategoryChoiceTask.any_instance.stubs(:call).raises("no chooser call expected")
          @n = 0
          @bare = ::Books::Book.create!(title: "No Genre Yet")
          @fiction_only = ::Books::Book.create!(title: "Only Fiction Held")
          @fiction_only.category_items.create!(category: categories(:books_fiction_genre), source: :legacy)
          @held = ::Books::Book.create!(title: "Has A Real Genre")
          @held.category_items.create!(category: categories(:books_novels_genre), source: :legacy)
          @inherited = ::Books::Book.create!(title: "Genre Only Inherited")
          @inherited.category_items.create!(category: categories(:books_classics_genre), source: :inherited)
          @untitled = ::Books::Book.create!(title: "x")
          @untitled.update_columns(title: "")
          @genre = ::Books::Category.create!(name: "Queue Test Genre", category_type: :genre, description: "  A   described\n genre ")
        end

        def fill(scope) = Services::EnrichmentQueue::Fill.call(kind: "books.categories", scope: scope)

        def answer(overrides = {})
          {"recognized" => true, "confidence" => "high", "book_type" => {"value" => "unknown", "confidence" => "low", "evidence" => "x"},
           "genres" => [{"id" => @genre.id, "confidence" => "high", "evidence" => "WorldCat"}],
           "audience" => {"id" => nil, "confidence" => "low", "evidence" => ""}, "subjects" => [], "locations" => [],
           "unlisted_genres" => []}.merge(overrides)
        end

        def request_for(book, body = answer, sources: ["https://example.org/a"])
          ::EnrichmentRequest.create!(enrichable: book, kind: "books.categories", reason: "missing", status: :submitted,
            answer: body, sources: sources, resolved_by: users(:admin_user))
        end

        def linked(book) = book.category_items.direct.includes(:category).map { [it.category.name, it.source] }

        test "candidates are titled books with no real direct genre" do
          ids = Type.candidates(scope: "all").pluck(:id)
          assert_includes ids, @bare.id
          assert_includes ids, @fiction_only.id
          assert_includes ids, @inherited.id
          assert_not_includes ids, @held.id
          assert_not_includes ids, @untitled.id
        end

        test "a book with a running enrichment or categorize run is left out" do
          [::Workflows::Books::BookEnrichment.workflow, ::Workflows::Books::BookCategorize.workflow].each do |workflow|
            run = WorkflowRun.create!(workflow: workflow, definition_version: 1, enrichable: @bare, status: :running, initiated_by: "test")
            assert_not_includes Type.candidates(scope: "all").pluck(:id), @bare.id, workflow
            run.destroy!
          end
        end

        test "an unknown scope raises" do
          assert_raises(ArgumentError) { Type.candidates(scope: "some") }
        end

        test "ranked scope keeps only ranked books and priority is the rank" do
          configuration = ::Books::RankingConfiguration.default_primary
          assert_not_nil configuration
          RankedItem.create!(item: @bare, ranking_configuration: configuration, rank: 42, score: 1)
          rows = Type.candidates(scope: "ranked").pluck(Arel.sql("books_books.id"), Arel.sql(Type.priority_sql))
          assert_equal [[@bare.id, 42]], rows
          assert_includes Type.candidates(scope: "all").pluck(:id), @fiction_only.id
        end

        test "still_needed? follows the data and ignores a running run" do
          assert Type.still_needed?(@bare)
          assert Type.still_needed?(@fiction_only)
          assert Type.still_needed?(@inherited)
          assert_not Type.still_needed?(@held)
          WorkflowRun.create!(workflow: ::Workflows::Books::BookCategorize.workflow, definition_version: 1,
            enrichable: @bare, status: :running, initiated_by: "test")
          assert Type.still_needed?(@bare)
        end

        test "payload carries the held categories with their sources" do
          @bare.category_items.create!(category: categories(:books_fiction_genre), source: :legacy)
          @bare.category_items.create!(category: @genre, source: :goodreads)
          payload = Type.payload(@bare)
          assert_equal @bare.id, payload["book_id"]
          assert_equal "No Genre Yet", payload["record"]["title"]
          held = payload["record"]["categories"].map { [it["name"], it["source"]] }
          assert_includes held, ["Queue Test Genre", "goodreads"]
        end

        test "payload tried is the latest categories row, whatever its mode" do
          assert_nil Type.payload(@bare)["tried"]
          @bare.enrichments.create!(kind: "books.categories", mode: :knowledge, outcome: :nothing_to_apply, reason: "nothing_applied")
          @bare.enrichments.create!(kind: "books.categories", mode: :agent, outcome: :applied, reason: "applied")
          assert_equal ["agent", "applied"], Type.payload(@bare)["tried"].values_at("mode", "outcome")
        end

        test "reference holds data only: schema, genres, audiences and caps" do
          reference = Type.reference
          assert_equal %w[answer_schema audiences caps genres], reference.keys.sort
          assert_equal({"genres" => 5, "subjects" => 8, "locations" => 5}, reference["caps"])
        end

        test "reference genres come from the judge vocabulary, sorted by name, without Fiction and Nonfiction" do
          audience = ::Books::Category.create!(name: "Queue Test Audience", category_type: :audience)
          genres = Type.reference["genres"]
          assert_equal %w[id name definition], genres.first.keys
          names = genres.map { it["name"] }
          assert_equal names.sort, names
          assert_not_includes names, "Fiction"
          assert_not_includes names, "Nonfiction"
          entry = genres.find { it["id"] == @genre.id }
          assert_equal ["Queue Test Genre", "A described genre"], entry.values_at("name", "definition")
          assert_equal [[audience.id, "Queue Test Audience", nil]], Type.reference["audiences"].select { it["id"] == audience.id }.map(&:values)
          assert_not_includes Type.reference["audiences"].map { it["id"] }, @genre.id
          assert_not_includes genres.map { it["id"] }, audience.id
        end

        test "the answer schema accepts a well-formed answer and rejects one missing genres" do
          schema = JSONSchemer.schema(Type.reference["answer_schema"])
          assert schema.valid?(answer)
          assert_not schema.valid?(answer.except("genres"))
        end

        test "apply links the genre and writes an agent ledger row from the request" do
          request = request_for(@bare)
          result = Type.apply(request)
          assert result.success?
          assert_equal "applied", result.data[:outcome]
          row = result.data[:enrichment]
          assert_equal ["books.categories", "agent", "agent", request.id], [row.kind, row.mode, row.provider, row.facts["queue_request_id"]]
          assert_equal ["agent", "agent"], row.facts.values_at("context", "label")
          assert_equal ["https://example.org/a"], row.citations
          assert_equal [["Queue Test Genre", "ai"]], linked(@bare)
        end

        test "apply removes nothing the answer did not pick" do
          other = ::Books::Category.create!(name: "Queue Legacy Genre", category_type: :genre)
          @bare.category_items.create!(category: other, source: :legacy)
          Type.apply(request_for(@bare))
          assert_includes linked(@bare), ["Queue Legacy Genre", "legacy"]
          assert_includes linked(@bare), ["Queue Test Genre", "ai"]
        end

        test "apply stores each source once" do
          row = Type.apply(request_for(@bare, sources: ["https://example.org/a", "https://example.org/a", "https://example.org/b"])).data[:enrichment]
          assert_equal ["https://example.org/a", "https://example.org/b"], row.citations
        end

        test "apply works when the automatic judge is switched off" do
          Rails.application.config.x.ai.stubs(:categories_judge_enabled).returns(false)
          result = Type.apply(request_for(@bare))
          assert result.success?
          assert_equal [["Queue Test Genre", "ai"]], linked(@bare)
        end

        test "apply returns a failure result when the row is failed" do
          Services::Books::Categories::Mapper.stubs(:call).returns(
            Services::Books::Categories::Mapper::Result.new(success?: false, errors: ["chooser down"])
          )
          result = Type.apply(request_for(@bare))
          assert_not result.success?
          assert_equal ["chooser down"], result.errors
          assert_equal "failed", result.data[:enrichment].outcome
        end

        test "is registered" do
          assert_equal Type, Services::EnrichmentQueue::Registry.fetch("books.categories")
        end

        test "kind, label and version" do
          assert_equal ["books.categories", "Book categories", Services::Ai::Tasks::Books::BookCategoriesTask::PROMPT_VERSION],
            [Type.kind, Type.label, Type.version]
        end

        test "fill inserts one pending row for a genreless book and none for one with a real genre" do
          result = fill("all")
          assert result.success?
          assert_equal 1, ::EnrichmentRequest.where(kind: "books.categories", enrichable: @bare).count
          assert_equal 1, ::EnrichmentRequest.where(kind: "books.categories", enrichable: @fiction_only).count
          assert_equal 0, ::EnrichmentRequest.where(kind: "books.categories", enrichable: @held).count
          assert_equal "pending", ::EnrichmentRequest.find_by!(kind: "books.categories", enrichable: @bare).status
        end

        test "ranked fill queues only the ranked genreless book, at its rank" do
          RankedItem.create!(item: @bare, ranking_configuration: ::Books::RankingConfiguration.default_primary, rank: 17, score: 1)
          result = fill("ranked")
          assert result.success?
          assert_equal 0, ::EnrichmentRequest.where(kind: "books.categories", enrichable: @fiction_only).count
          assert_equal 17, ::EnrichmentRequest.find_by!(kind: "books.categories", enrichable: @bare).priority
        end

        test "paid_research? is true" do
          assert Type.paid_research?
        end

        test "research runs the forced paid path and maps its row" do
          record = ::Books::Book.create!(title: "Forced Categories")
          request = ::EnrichmentRequest.new(enrichable: record, kind: Type.kind)
          {
            [:applied, nil, nil] => [true, "applied"],
            [:failed, "model down", nil] => [false, nil],
            [:skipped, nil, "disabled"] => [false, nil]
          }.each do |(outcome, error, reason), (success, expected_outcome)|
            row = record.enrichments.create!(kind: Type.kind, mode: :research, outcome: outcome, error: error, reason: reason, facts: {})
            Services::Books::Categories::Judge.expects(:call).with(book: record, context: "queue", label: "queue", force_research: true).returns(Services::Books::Categories::Judge::Result.new(success?: outcome != :failed, data: {enrichments: [row]}, errors: []))

            result = Type.research(request)

            assert_equal success, result.success?, outcome
            assert_equal expected_outcome, result.data[:outcome] if success
            assert_equal [error || "skipped: disabled"], result.errors unless success
          end
        end
      end
    end
  end
end
