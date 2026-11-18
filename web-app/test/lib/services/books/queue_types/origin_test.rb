require "test_helper"

module Services
  module Books
    module QueueTypes
      class OriginTest < ActiveSupport::TestCase
        Type = Services::Books::QueueTypes::Origin

        setup do
          @blank = ::Books::Book.create!(title: "No Country Yet")
          @placed = ::Books::Book.create!(title: "Has A Country")
          @placed.book_countries.create!(country: ::Books::Country.find_by!(name: "French"))
        end

        def fill(scope) = Services::EnrichmentQueue::Fill.call(kind: "books.origin", scope: scope)

        test "candidates are titled books with no real country" do
          ids = Type.candidates(scope: "all").pluck(:id)
          assert_includes ids, @blank.id
          assert_not_includes ids, @placed.id
        end

        test "a book holding only a placeholder country is still a candidate" do
          @blank.book_countries.create!(country: ::Books::Country.find_or_create_by!(name: "Unknown"))
          assert_includes Type.candidates(scope: "all").pluck(:id), @blank.id
        end

        test "a book with a blank title is not a candidate" do
          untitled = ::Books::Book.create!(title: "x")
          untitled.update_columns(title: "")
          assert_not_includes Type.candidates(scope: "all").pluck(:id), untitled.id
        end

        test "a book with a running enrichment or categorize run is left out" do
          [::Workflows::Books::BookEnrichment.workflow, ::Workflows::Books::BookCategorize.workflow].each do |workflow|
            run = WorkflowRun.create!(workflow: workflow, definition_version: 1, enrichable: @blank, status: :running, initiated_by: "test")
            assert_not_includes Type.candidates(scope: "all").pluck(:id), @blank.id, workflow
            run.destroy!
          end
        end

        test "an unknown scope raises" do
          assert_raises(ArgumentError) { Type.candidates(scope: "some") }
        end

        test "ranked scope keeps only ranked books and priority is the rank" do
          configuration = ::Books::RankingConfiguration.default_primary
          assert_not_nil configuration
          RankedItem.create!(item: @blank, ranking_configuration: configuration, rank: 42, score: 1)
          rows = Type.candidates(scope: "ranked").pluck(Arel.sql("books_books.id"), Arel.sql(Type.priority_sql))
          assert_equal [[@blank.id, 42]], rows
        end

        test "still_needed? follows the data" do
          assert Type.still_needed?(@blank)
          assert_not Type.still_needed?(@placed)
        end

        test "still_needed? ignores a running run" do
          WorkflowRun.create!(workflow: ::Workflows::Books::BookCategorize.workflow, definition_version: 1,
            enrichable: @blank, status: :running, initiated_by: "test")
          assert Type.still_needed?(@blank)
        end

        test "payload carries the record, the stored evidence and what was tried" do
          @blank.enrichments.create!(kind: "books.origin", mode: :knowledge, outcome: :nothing_to_apply, reason: "low_confidence",
            confidence: :low, facts: {"answer" => {"nationality" => "Japanese", "confidence" => "low"}})
          payload = Type.payload(@blank)
          assert_equal @blank.id, payload["book_id"]
          assert_equal "No Country Yet", payload["record"]["title"]
          assert_equal %w[book_facts goodreads wikidata wikipedia worldcat], payload["evidence"].keys.sort
          assert_equal ["knowledge", "nothing_to_apply", "low_confidence"], payload["tried"].values_at("mode", "outcome", "reason")
        end

        test "payload tried is nil when nothing was tried" do
          assert_nil Type.payload(@blank)["tried"]
        end

        test "an agent row counts as tried" do
          @blank.enrichments.create!(kind: "books.origin", mode: :knowledge, outcome: :nothing_to_apply, reason: "low_confidence")
          @blank.enrichments.create!(kind: "books.origin", mode: :agent, outcome: :applied, reason: "filled")
          assert_equal "agent", Type.payload(@blank)["tried"]["mode"]
        end

        test "reference carries the answer schema and it accepts a well-formed answer" do
          schema = JSONSchemer.schema(Type.reference["answer_schema"])
          assert schema.valid?({"recognized" => true, "original_language" => nil, "nationality" => "Japanese", "confidence" => "high", "reason" => "r"})
          assert_not schema.valid?({"nationality" => "Japanese"})
        end

        test "apply writes the country and an agent ledger row from the request" do
          request = ::EnrichmentRequest.create!(enrichable: @blank, kind: "books.origin", reason: "missing", status: :submitted,
            answer: {"recognized" => true, "original_language" => "Japanese", "nationality" => "Japanese", "confidence" => "high", "reason" => "r"},
            sources: ["https://example.org/a"], resolved_by: users(:admin_user))
          result = Type.apply(request)
          assert result.success?
          assert_equal "applied", result.data[:outcome]
          row = result.data[:enrichment]
          assert_equal ["books.origin", "agent", "agent", request.id], [row.kind, row.mode, row.provider, row.facts["queue_request_id"]]
          assert_equal ["https://example.org/a"], row.citations
        end

        test "is registered" do
          assert_equal Type, Services::EnrichmentQueue::Registry.fetch("books.origin")
        end

        test "fill inserts one pending row at the unranked priority for a countryless book and none for a placed one" do
          result = fill("all")
          assert result.success?
          rows = ::EnrichmentRequest.where(kind: "books.origin", enrichable: @blank)
          assert_equal 1, rows.count
          assert_equal ["pending", 1_000_000], [rows.first.status, rows.first.priority]
          assert_equal 0, ::EnrichmentRequest.where(kind: "books.origin", enrichable: @placed).count
        end

        test "ranked fill queues a ranked countryless book at its rank" do
          RankedItem.create!(item: @blank, ranking_configuration: ::Books::RankingConfiguration.default_primary, rank: 17, score: 1)
          result = fill("ranked")
          assert result.success?
          assert_equal 1, result.data[:inserted]
          assert_equal 17, ::EnrichmentRequest.find_by!(kind: "books.origin", enrichable: @blank).priority
        end
      end
    end
  end
end
