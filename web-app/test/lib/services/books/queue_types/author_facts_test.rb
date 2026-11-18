require "test_helper"

module Services
  module Books
    module QueueTypes
      class AuthorFactsTest < ActiveSupport::TestCase
        Type = Services::Books::QueueTypes::AuthorFacts
        KIND = "books.author_facts"
        DESCRIPTION = ("Her poems and essays followed Paris between the wars, and she edited a small review that printed young writers. " * 3).strip

        setup do
          stub_review(style_violations: [], rewritten: nil)
        end

        def stub_review(style_violations:, rewritten:, success: true)
          review = mock
          result = if success
            Services::Ai::Result.new(success: true, data: {style_violations: style_violations, rewritten: rewritten})
          else
            Services::Ai::Result.new(success: false, error: "review down")
          end
          review.stubs(:call).returns(result)
          Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.stubs(:new).returns(review)
        end

        def new_author(name = "Anna Brenner", **attrs) = ::Books::Author.create!(name: name, **attrs)

        def candidate_ids = Type.candidates(scope: "all").pluck(:id)

        def fact(value, confidence = "high") = {"value" => value, "confidence" => confidence}

        def answer(overrides = {})
          {
            "recognized" => true, "confidence" => "high",
            "birth_year" => fact(1901), "death_year" => fact(nil, "low"),
            "gender" => fact("female"), "nationalities" => fact(["French"]),
            "description" => fact(DESCRIPTION)
          }.merge(overrides)
        end

        def request_for(author, body = answer, sources: ["https://example.org/a", "https://example.org/b", "https://example.org/a"])
          ::EnrichmentRequest.create!(enrichable: author, kind: KIND, reason: "missing", status: :submitted,
            answer: body, sources: sources, resolved_by: users(:admin_user))
        end

        def skip_research(author)
          author.enrichments.create!(kind: KIND, mode: :research, outcome: :skipped, reason: "budget_exhausted")
        end

        test "an author whose newest row is a research skip is a candidate, other states are not" do
          skipped = new_author("Skipped One")
          skip_research(skipped)
          answered = new_author("Answered One")
          skip_research(answered)
          answered.enrichments.create!(kind: KIND, mode: :research, outcome: :applied, reason: "filled")
          untouched = new_author("Untouched One")
          knowledge_skip = new_author("Knowledge Skip")
          knowledge_skip.enrichments.create!(kind: KIND, mode: :knowledge, outcome: :skipped, reason: "complete")

          ids = candidate_ids
          assert_includes ids, skipped.id
          assert_not_includes ids, answered.id
          assert_not_includes ids, untouched.id
          assert_not_includes ids, knowledge_skip.id
        end

        test "a placeholder with a research skip is not a candidate" do
          placeholder = new_author("Unknown Hand", exclude_from_rankings: true)
          skip_research(placeholder)
          assert_not_includes candidate_ids, placeholder.id
        end

        test "an author with a running enrichment run is left out" do
          author = new_author("Being Enriched")
          skip_research(author)
          assert_includes candidate_ids, author.id
          WorkflowRun.create!(workflow: ::Workflows::Books::AuthorEnrichment.workflow, definition_version: 1,
            enrichable: author, status: :running, initiated_by: "test")
          assert_not_includes candidate_ids, author.id
        end

        test "ranked scope keeps ranked authors and priority is the rank" do
          ranked = new_author("Ranked Skip")
          unranked = new_author("Unranked Skip")
          [ranked, unranked].each { |author| skip_research(author) }
          RankedItem.create!(item: ranked, ranking_configuration: ::Books::Authors::RankingConfiguration.default_primary, rank: 42, score: 1)
          rows = Type.candidates(scope: "ranked").pluck(Arel.sql("books_authors.id"), Arel.sql(Type.priority_sql))
          assert_equal [[ranked.id, 42]], rows
          assert_includes candidate_ids, unranked.id
          assert_raises(ArgumentError) { Type.candidates(scope: "bogus") }
        end

        test "priority_for is the rank or the unranked constant" do
          ranked = new_author("Ranked Pri")
          unranked = new_author("Unranked Pri")
          RankedItem.create!(item: ranked, ranking_configuration: ::Books::Authors::RankingConfiguration.default_primary, rank: 7, score: 1)
          assert_equal 7, Type.priority_for(ranked)
          assert_equal AuthorScope::UNRANKED_PRIORITY, Type.priority_for(unranked)
        end

        test "still_needed? follows the ledger" do
          author = new_author("Needed Author")
          assert_not Type.still_needed?(author)
          skip_research(author)
          assert Type.still_needed?(author)
          WorkflowRun.create!(workflow: ::Workflows::Books::AuthorEnrichment.workflow, definition_version: 1,
            enrichable: author, status: :running, initiated_by: "test")
          assert Type.still_needed?(author)
          author.enrichments.create!(kind: KIND, mode: :research, outcome: :applied, reason: "filled")
          assert_not Type.still_needed?(author)
          placeholder = new_author("Placeholder", exclude_from_rankings: true)
          skip_research(placeholder)
          assert_not Type.still_needed?(placeholder)
        end

        test "payload carries the author, their books and what was tried" do
          author = new_author("Payload Author", birth_year: 1901, alternate_names: (1..12).map { |i| "Alias #{i}" })
          author.countries << books_countries(:french)
          book = ::Books::Book.create!(title: "Her Only Book", first_published_year: 1930)
          book.book_authors.create!(author: author, position: 1)

          payload = Type.payload(author)
          assert_equal author.id, payload["author_id"]
          record = payload["record"]
          assert_equal "Payload Author", record["name"]
          assert_equal 10, record["alternate_names"].size
          assert_equal [1901, nil], [record["birth_year"], record["death_year"]]
          assert_equal [books_countries(:french).name], record["countries"]
          assert_equal [{"title" => "Her Only Book", "first_published_year" => 1930}], record["books"]
          assert_equal false, record["has_description"]
          assert_nil payload["tried"]

          author.descriptions.create!(content: "Old text.", source: :wikipedia, rank: :deprecated)
          assert_equal false, Type.payload(author)["record"]["has_description"]
          author.descriptions.create!(content: "A text.", source: :manual, rank: :normal)
          assert_equal true, Type.payload(author)["record"]["has_description"]

          author.enrichments.create!(kind: KIND, mode: :knowledge, outcome: :applied, reason: "filled", confidence: :high,
            facts: {"birth_year" => {"value" => 1901}, "context" => {"value" => "x"}})
          skip_research(author)
          tried = Type.payload(author)["tried"]
          assert_equal ["knowledge", "applied", "high"], tried.values_at("mode", "outcome", "confidence")
          assert_equal ["birth_year"], tried["facts"].keys
        end

        test "the answer schema accepts a full answer and rejects one with a key missing" do
          schema = JSONSchemer.schema(Type.answer_schema)
          assert_equal Type.answer_schema, Type.reference["answer_schema"]
          assert schema.valid?(answer)
          assert_not schema.valid?(answer.except("description"))
        end

        test "apply writes an agent row and fills blanks" do
          author = new_author("Fresh Author")
          request = request_for(author)
          result = Type.apply(request)
          row = result.data[:enrichment]
          assert result.success?
          assert_equal "applied", result.data[:outcome]
          assert_equal [KIND, "agent", "agent"], [row.kind, row.mode, row.provider]
          assert_equal ["https://example.org/a", "https://example.org/b"], row.citations
          assert_equal "agent", row.facts["context"]["value"]
          assert_equal request.id, row.facts["queue_request_id"]["value"]
          assert row.facts.key?("sources")
          author.reload
          assert_equal 1901, author.birth_year
          assert_equal "female", author.gender
          assert_equal [books_countries(:french)], author.countries.to_a
          assert_equal DESCRIPTION, author.descriptions.first.content
        end

        test "apply never overwrites a held value" do
          author = new_author("Held Author", birth_year: 1900)
          row = Type.apply(request_for(author, answer("birth_year" => fact(1901)))).data[:enrichment]
          assert_equal 1900, author.reload.birth_year
          assert_equal "conflict", row.facts["birth_year"]["reason"]
        end

        test "apply records what the catalogue cannot use" do
          author = new_author("Unusable Author")
          body = answer(
            "birth_year" => fact(Time.current.year + 5), "gender" => fact("unknown"),
            "nationalities" => fact(["Klingonese"]), "description" => fact(nil, "low")
          )
          result = Type.apply(request_for(author, body))
          row = result.data[:enrichment]
          assert_equal "nothing_to_apply", result.data[:outcome]
          %w[birth_year gender countries].each do |name|
            assert_equal false, row.facts[name]["applied"], name
          end
          author.reload
          assert_nil author.birth_year
          assert_nil author.gender
          assert_empty author.countries
        end

        test "a low overall confidence is held" do
          author = new_author("Shaky Author")
          result = Type.apply(request_for(author, answer("confidence" => "low")))
          row = result.data[:enrichment]
          assert_equal "nothing_to_apply", result.data[:outcome]
          assert_equal "low_confidence", row.facts["birth_year"]["reason"]
          assert_nil author.reload.birth_year
          assert_empty author.descriptions
        end

        test "an unrecognized answer ends unrecognized" do
          author = new_author("Unknown To Us")
          result = Type.apply(request_for(author, answer("recognized" => false)))
          assert_equal "unrecognized", result.data[:outcome]
          assert_nil author.reload.birth_year
        end

        test "a failed review call raises and writes nothing" do
          stub_review(style_violations: [], rewritten: nil, success: false)
          author = new_author("Review Down")
          request = request_for(author)
          assert_no_difference -> { Enrichment.count } do
            error = assert_raises(Services::Books::Authors::RecordAuthorFacts::ReviewFailed) { Type.apply(request) }
            assert_includes error.message, "review down"
          end
          assert_nil author.reload.birth_year
          assert_empty author.descriptions
        end

        test "submit to done, end to end" do
          author = new_author("End To End")
          skip_research(author)
          Services::EnrichmentQueue::Fill.call(kind: KIND, scope: "all")
          row = ::EnrichmentRequest.find_by!(kind: KIND, enrichable: author)
          claim = Services::EnrichmentQueue::Claim.call(kind: KIND, user: users(:admin_user), limit: 25)
          assert_equal "claimed", row.reload.status
          result = Services::EnrichmentQueue::Submit.call(request: row, lease_token: claim.data[:lease_token], answer: answer,
            sources: ["https://example.org/a"], user: users(:admin_user))
          assert result.success?, result.errors.inspect
          row.reload
          assert_equal ["done", "applied"], [row.status, row.outcome]
          assert_not_nil row.enrichment
          assert_equal 1901, author.reload.birth_year
        end

        test "is registered" do
          assert_equal Type, Services::EnrichmentQueue::Registry.find(domain: "books", slug: "author_facts")
        end
      end
    end
  end
end
