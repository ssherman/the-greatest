# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class RecordAuthorFactsTest < ActiveSupport::TestCase
        DESCRIPTION = ("Her poems and essays followed Paris between the wars, and she edited a small review that printed young writers. " * 3).strip
        INPUT_ENTRY = {"value" => "agent", "applied" => false, "reason" => "input"}
        SOURCES = [{"source" => "wikidata", "source_id" => "Q1"}]

        def setup
          @author = ::Books::Author.create!(name: "Anna Brenner")
          @records = stub(wikidata: nil, viaf: nil, lead: nil, matched?: true, sources: SOURCES)
          stub_review(style_violations: [], rewritten: nil)
        end

        def facts(overrides = {})
          {
            recognized: true, confidence: "high",
            birth_year: {value: 1901, confidence: "high"},
            death_year: {value: nil, confidence: "low"},
            gender: {value: "female", confidence: "high"},
            nationalities: {value: ["French"], confidence: "high"},
            description: {value: DESCRIPTION, confidence: "high"}
          }.deep_merge(overrides)
        end

        def stub_review(style_violations:, rewritten:, success: true, data: nil)
          review = mock
          result = if success
            ::Services::Ai::Result.new(success: true, data: data || {style_violations: style_violations, rewritten: rewritten})
          else
            ::Services::Ai::Result.new(success: false, error: "review down")
          end
          review.stubs(:call).returns(result)
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.stubs(:new).returns(review)
        end

        def record(facts_hash = facts, **options)
          RecordAuthorFacts.call(author: @author, records: @records, facts: facts_hash, mode: :agent, **options)
        end

        test "KIND is the author facts ledger kind" do
          assert_equal "books.author_facts", RecordAuthorFacts::KIND
          assert_equal RecordAuthorFacts::KIND, EnrichAuthor::KIND
        end

        test "sources_fact records the matched sources as an input entry" do
          assert_equal({"sources" => {"value" => SOURCES, "applied" => false, "reason" => "input"}}, RecordAuthorFacts.sources_fact(@records))
        end

        test "a recognized answer fills blanks and writes one applied row with the sources entry" do
          row = record(provider: "agent", citations: ["https://example.org/a"])

          assert_equal "books.author_facts", row.kind
          assert_equal "agent", row.mode
          assert_equal "applied", row.outcome
          assert row.recognized
          assert_equal "agent", row.provider
          assert_equal ["https://example.org/a"], row.citations
          assert_equal 1901, @author.reload.birth_year
          assert row.facts["birth_year"]["applied"]
          assert_equal SOURCES, row.facts["sources"]["value"]
        end

        test "an unrecognized answer applies nothing" do
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.expects(:new).never

          row = record(facts(recognized: false))

          assert_equal "unrecognized", row.outcome
          assert_equal false, row.recognized
          assert row.facts.except("sources").values.all? { |entry| entry["applied"] == false && entry["reason"] == "unrecognized" }
          assert_nil @author.reload.birth_year
        end

        test "a low overall confidence is held under the given reason without a review call" do
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.expects(:new).never

          row = record(facts(confidence: "low"), hold_low_confidence: "low_confidence")

          assert_equal "nothing_to_apply", row.outcome
          assert row.facts.except("sources").values.all? { |entry| entry["reason"] == "low_confidence" }
          assert_nil @author.reload.birth_year
          assert_empty @author.descriptions
        end

        test "a low overall confidence is applied when nothing holds it" do
          row = record(facts(confidence: "low"), hold_low_confidence: nil)

          assert_equal "applied", row.outcome
          assert_equal 1901, @author.reload.birth_year
        end

        test "a held reason does not touch a medium answer" do
          row = record(facts(confidence: "medium"), hold_low_confidence: "deferred")

          assert_equal "applied", row.outcome
          assert_equal 1901, @author.reload.birth_year
        end

        test "a low confidence fact is recorded low_confidence and the other facts apply" do
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.expects(:new).never

          row = record(facts(description: {confidence: "low"}))

          assert_equal "applied", row.outcome
          assert_equal "low_confidence", row.facts["description"]["reason"]
          assert_equal false, row.facts["description"]["applied"]
          assert_equal 1901, @author.reload.birth_year
          assert_empty @author.descriptions
        end

        test "strict review raises before anything is written when the review call fails" do
          stub_review(style_violations: [], rewritten: nil, success: false)

          assert_no_difference -> { Enrichment.count } do
            assert_raises(RecordAuthorFacts::ReviewFailed) { record(strict_review: true) }
          end
          assert_nil @author.reload.birth_year
          assert_empty @author.descriptions
        end

        test "strict review raises when the review succeeds but returns no verdict" do
          stub_review(style_violations: nil, rewritten: nil, data: {})

          assert_no_difference -> { Enrichment.count } do
            assert_raises(RecordAuthorFacts::ReviewFailed) { record(strict_review: true) }
          end
          assert_nil @author.reload.birth_year
          assert_empty @author.descriptions
        end

        test "without strict review a failed review records review_failed and the other facts apply" do
          stub_review(style_violations: [], rewritten: nil, success: false)

          row = record

          assert_equal "review_failed", row.facts["description"]["reason"]
          assert_equal 1901, @author.reload.birth_year
        end

        test "extra_facts are merged into every kind of row" do
          extra = {"context" => INPUT_ENTRY}

          applied = record(extra_facts: extra)
          unrecognized = record(facts(recognized: false), extra_facts: extra)
          held = record(facts(confidence: "low"), hold_low_confidence: "low_confidence", extra_facts: extra)

          [applied, unrecognized, held].each do |row|
            assert_equal INPUT_ENTRY, row.facts["context"]
            assert_equal SOURCES, row.facts["sources"]["value"]
          end
        end
      end
    end
  end
end
