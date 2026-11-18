require "test_helper"

module Services
  module Books
    module QueueTypes
      class BookFactsTest < ActiveSupport::TestCase
        Type = Services::Books::QueueTypes::BookFacts
        CLEAN_DESCRIPTION = ("In a small Connecticut town, a young man takes a job caring for an elderly widow. " * 3).strip

        setup do
          stub_review(spoilers: false, style_violations: [], rewritten: nil)
        end

        def stub_review(spoilers:, style_violations:, rewritten:, success: true)
          review = mock
          result = if success
            Services::Ai::Result.new(success: true, data: {spoilers: spoilers, spoiler_notes: nil, style_violations: style_violations, rewritten: rewritten})
          else
            Services::Ai::Result.new(success: false, error: "review down")
          end
          review.stubs(:call).returns(result)
          Services::Ai::Tasks::Books::DescriptionReviewTask.stubs(:new).returns(review)
        end

        def book_with_author(title, **attrs)
          book = ::Books::Book.create!(title: title, **attrs)
          book.book_authors.create!(author: books_authors(:tolstoy), position: 1)
          book
        end

        def add_description(book, rank: :normal)
          book.descriptions.create!(content: "A description.", source: ((rank == :deprecated) ? :wikipedia : :manual), rank: rank)
        end

        def complete(book)
          book.update!(first_published_year: 1869, original_language: languages(:russian))
          add_description(book)
          book
        end

        def candidate_ids = Type.candidates(scope: "all").pluck(:id)

        def fact(value, confidence = "high") = {"value" => value, "confidence" => confidence}

        def answer(overrides = {})
          {
            "recognized" => true, "confidence" => "high",
            "first_published_year" => fact(1869), "first_published_year_estimated" => false,
            "original_language" => fact("Russian"), "word_count" => fact(nil, "low"), "page_range" => fact(nil, "low"),
            "subtitle" => fact(nil, "low"), "alternate_titles" => fact([], "low"), "origin_countries" => fact([], "low"),
            "book_type" => fact("fiction"), "series_name" => fact(nil, "low"), "series_number" => fact(nil, "low"),
            "description" => fact(CLEAN_DESCRIPTION)
          }.merge(overrides)
        end

        def request_for(book, body = answer, sources: ["https://example.org/a", "https://example.org/b", "https://example.org/a"])
          ::EnrichmentRequest.create!(enrichable: book, kind: "books.book_facts", reason: "missing", status: :submitted,
            answer: body, sources: sources, resolved_by: users(:admin_user))
        end

        test "a book missing its year is a candidate and a complete book is not" do
          missing = book_with_author("Missing Year", original_language: languages(:russian))
          add_description(missing)
          done = complete(book_with_author("All There"))
          assert_includes candidate_ids, missing.id
          assert_not_includes candidate_ids, done.id
        end

        test "a book with no author is not a candidate" do
          orphan = ::Books::Book.create!(title: "Orphan")
          assert_not_includes candidate_ids, orphan.id
        end

        test "a book with a blank title is not a candidate" do
          untitled = book_with_author("x")
          untitled.update_columns(title: "")
          assert_not_includes candidate_ids, untitled.id
        end

        test "a book with a running enrichment run is left out" do
          book = book_with_author("Being Enriched")
          WorkflowRun.create!(workflow: ::Workflows::Books::BookEnrichment.workflow, definition_version: 1,
            enrichable: book, status: :running, initiated_by: "test")
          assert_not_includes candidate_ids, book.id
        end

        test "a book whose only description is deprecated is a candidate" do
          book = book_with_author("Deprecated Only", first_published_year: 1869, original_language: languages(:russian))
          add_description(book, rank: :deprecated)
          assert_includes candidate_ids, book.id
          add_description(book)
          assert_not_includes candidate_ids, book.id
        end

        test "a field a human cleared is not a gap" do
          book = book_with_author("Cleared Year", original_language: languages(:russian))
          add_description(book)
          assert_includes candidate_ids, book.id

          book.cleared_fields.create!(field_name: "first_published_year", cleared_via: :admin_ui)
          assert_not_includes candidate_ids, book.id

          book.update!(original_language: nil)
          assert_includes candidate_ids, book.id
        end

        test "an applied blank correction is not a gap" do
          book = book_with_author("Corrected Year", original_language: languages(:russian))
          add_description(book)
          correction = ::Correction.create!(correctable: book, status: :resolved, notes: "cleared")
          correction.correction_fields.create!(field_name: "first_published_year", status: :applied, new_value: "", applied_at: Time.current)
          assert_not_includes candidate_ids, book.id
        end

        test "a complete book whose newest book_facts row is a research skip is a candidate" do
          book = complete(book_with_author("Skipped Research"))
          book.enrichments.create!(kind: "books.book_facts", mode: :research, outcome: :skipped, reason: "budget_exhausted")
          assert_includes candidate_ids, book.id

          book.enrichments.create!(kind: "books.book_facts", mode: :knowledge, outcome: :applied, reason: "filled")
          assert_not_includes candidate_ids, book.id
        end

        test "a deferred_to_authors skip is not a research skip" do
          book = complete(book_with_author("Deferred To Authors"))
          book.enrichments.create!(kind: "books.book_facts", mode: :knowledge, outcome: :skipped, reason: "deferred_to_authors")
          assert_not_includes candidate_ids, book.id
        end

        test "ranked scope keeps only ranked books and priority is the rank" do
          ranked = book_with_author("Ranked Gap")
          unranked = book_with_author("Unranked Gap")
          RankedItem.create!(item: ranked, ranking_configuration: ::Books::RankingConfiguration.default_primary, rank: 42, score: 1)
          rows = Type.candidates(scope: "ranked").pluck(Arel.sql("books_books.id"), Arel.sql(Type.priority_sql))
          assert_equal [[ranked.id, 42]], rows
          assert_includes candidate_ids, unranked.id
        end

        test "still_needed? follows the data and ignores a running run" do
          book = book_with_author("Needed")
          assert Type.still_needed?(book)
          WorkflowRun.create!(workflow: ::Workflows::Books::BookEnrichment.workflow, definition_version: 1,
            enrichable: book, status: :running, initiated_by: "test")
          assert Type.still_needed?(book)
          complete(book)
          assert_not Type.still_needed?(book)
          assert_not Type.still_needed?(::Books::Book.create!(title: "No Author"))
        end

        test "payload names what is missing and what was tried" do
          book = book_with_author("Empty Book")
          payload = Type.payload(book)
          assert_equal book.id, payload["book_id"]
          assert_equal "Empty Book", payload["record"]["title"]
          assert_equal %w[first_published_year original_language description], payload["missing"]
          assert_equal %w[goodreads wikidata wikipedia worldcat], payload["evidence"].keys.sort
          assert_nil payload["tried"]

          book.cleared_fields.create!(field_name: "first_published_year", cleared_via: :api)
          assert_equal %w[original_language description], Type.payload(book)["missing"]

          book.enrichments.create!(kind: "books.book_facts", mode: :knowledge, outcome: :applied, reason: "filled",
            facts: {"first_published_year" => {"value" => 1900}, "context" => {"value" => "x"}})
          book.enrichments.create!(kind: "books.book_facts", mode: :research, outcome: :skipped, reason: "budget_exhausted")
          tried = Type.payload(book)["tried"]
          assert_equal ["knowledge", "applied"], tried.values_at("mode", "outcome")
          assert_equal ["first_published_year"], tried["facts"].keys
        end

        test "the answer schema accepts a full answer and rejects one with a key missing" do
          schema = JSONSchemer.schema(Type.answer_schema)
          assert_equal Type.answer_schema, Type.reference["answer_schema"]
          assert schema.valid?(answer)
          assert_not schema.valid?(answer.except("description"))
        end

        test "apply writes an agent row and fills blanks" do
          book = book_with_author("Fresh")
          request = request_for(book)
          result = Type.apply(request)
          row = result.data[:enrichment]
          assert result.success?
          assert_equal "applied", result.data[:outcome]
          assert_equal ["books.book_facts", "agent", "agent"], [row.kind, row.mode, row.provider]
          assert_equal ["https://example.org/a", "https://example.org/b"], row.citations
          assert_equal "agent", row.facts["context"]["value"]
          assert_equal request.id, row.facts["queue_request_id"]["value"]
          book.reload
          assert_equal [1869, languages(:russian)], [book.first_published_year, book.original_language]
          assert_equal CLEAN_DESCRIPTION, book.descriptions.first.content
        end

        test "apply never overwrites a held value" do
          book = book_with_author("Held", first_published_year: 1869)
          row = Type.apply(request_for(book, answer("first_published_year" => fact(1870)))).data[:enrichment]
          assert_equal 1869, book.reload.first_published_year
          assert_equal "already_set", row.facts["first_published_year"]["reason"]
        end

        test "apply records what the catalogue cannot use" do
          book = book_with_author("Unusable")
          body = answer(
            "first_published_year" => fact(nil, "low"), "original_language" => fact("Klingonese"),
            "page_range" => fact("about 300"), "book_type" => fact(nil, "low"), "description" => fact(nil, "low")
          )
          result = Type.apply(request_for(book, body))
          row = result.data[:enrichment]
          assert_equal "nothing_to_apply", result.data[:outcome]
          assert_equal "no_match", row.facts["original_language"]["reason"]
          assert_equal "invalid", row.facts["page_range"]["reason"]
          book.reload
          assert_nil book.first_published_year
          assert_nil book.original_language
        end

        test "apply never refills a field a human cleared" do
          book = book_with_author("Human Cleared")
          book.cleared_fields.create!(field_name: "first_published_year", cleared_via: :admin_ui)
          row = Type.apply(request_for(book)).data[:enrichment]
          assert_nil book.reload.first_published_year
          assert_equal "human_cleared", row.facts["first_published_year"]["reason"]
        end

        test "an unrecognized answer ends unrecognized" do
          book = book_with_author("Unknown To Us")
          result = Type.apply(request_for(book, answer("recognized" => false)))
          assert_equal "unrecognized", result.data[:outcome]
          assert_nil book.reload.first_published_year
        end

        test "a low overall confidence is held" do
          book = book_with_author("Shaky")
          result = Type.apply(request_for(book, answer("confidence" => "low")))
          row = result.data[:enrichment]
          assert_equal "nothing_to_apply", result.data[:outcome]
          assert_equal "low_confidence", row.facts["first_published_year"]["reason"]
          assert_nil book.reload.first_published_year
          assert_empty book.descriptions
        end

        test "a failed review call raises and writes nothing" do
          stub_review(spoilers: nil, style_violations: [], rewritten: nil, success: false)
          book = book_with_author("Review Down")
          request = request_for(book)
          assert_no_difference -> { Enrichment.count } do
            assert_raises(Services::Books::RecordBookFacts::ReviewFailed) { Type.apply(request) }
          end
          assert_nil book.reload.first_published_year
          assert_empty book.descriptions
        end

        test "submit to done, end to end" do
          book = book_with_author("End To End")
          Services::EnrichmentQueue::Fill.call(kind: "books.book_facts", scope: "all")
          row = ::EnrichmentRequest.find_by!(kind: "books.book_facts", enrichable: book)
          claim = Services::EnrichmentQueue::Claim.call(kind: "books.book_facts", user: users(:admin_user), limit: 25)
          assert_equal "claimed", row.reload.status
          result = Services::EnrichmentQueue::Submit.call(request: row, lease_token: claim.data[:lease_token], answer: answer,
            sources: ["https://example.org/a"], user: users(:admin_user))
          assert result.success?, result.errors.inspect
          row.reload
          assert_equal ["done", "applied"], [row.status, row.outcome]
          assert_not_nil row.enrichment
          assert_equal 1869, book.reload.first_published_year
        end

        test "a done row is not queued again while the gap remains" do
          book = book_with_author("Gap Remains")
          Services::EnrichmentQueue::Fill.call(kind: "books.book_facts", scope: "all")
          row = ::EnrichmentRequest.find_by!(kind: "books.book_facts", enrichable: book)
          claim = Services::EnrichmentQueue::Claim.call(kind: "books.book_facts", user: users(:admin_user), limit: 25)
          row.reload
          body = answer("original_language" => fact(nil, "low"))
          submit = Services::EnrichmentQueue::Submit.call(request: row, lease_token: claim.data[:lease_token], answer: body,
            sources: ["https://example.org/a"], user: users(:admin_user))
          assert submit.success?, submit.errors.inspect
          assert_equal "done", row.reload.status
          assert_nil book.reload.original_language_id
          assert Type.still_needed?(book)
          assert_equal 0, Services::EnrichmentQueue::Fill.call(kind: "books.book_facts", scope: "all").data[:inserted]
          assert_equal "done", row.reload.status
        end

        test "is registered" do
          assert_equal Type, Services::EnrichmentQueue::Registry.find(domain: "books", slug: "book_facts")
        end
      end
    end
  end
end
