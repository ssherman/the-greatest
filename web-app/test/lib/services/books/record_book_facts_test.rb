require "test_helper"

module Services
  module Books
    class RecordBookFactsTest < ActiveSupport::TestCase
      CLEAN_DESCRIPTION = ("In a small Connecticut town, a young man takes a job caring for an elderly widow. " * 3).strip
      INPUT_ENTRY = {"value" => "agent", "applied" => false, "reason" => "input"}

      def setup
        @book = ::Books::Book.create!(title: "A Fresh Book")
        @book.book_authors.create!(author: books_authors(:tolstoy), position: 1)
        stub_review(spoilers: false, style_violations: [], rewritten: nil)
      end

      def facts(overrides = {})
        {
          recognized: true,
          confidence: "high",
          first_published_year: {value: 1999, confidence: "high"},
          first_published_year_estimated: false,
          original_language: {value: nil, confidence: "low"},
          word_count: {value: nil, confidence: "low"},
          page_range: {value: nil, confidence: "low"},
          subtitle: {value: nil, confidence: "low"},
          alternate_titles: {value: [], confidence: "low"},
          origin_countries: {value: [], confidence: "low"},
          book_type: {value: "fiction", confidence: "high"},
          series_name: {value: nil, confidence: "low"},
          series_number: {value: nil, confidence: "low"},
          description: {value: CLEAN_DESCRIPTION, confidence: "high"}
        }.deep_merge(overrides)
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

      def record(facts_hash = facts, **options)
        RecordBookFacts.call(book: @book, facts: facts_hash, mode: :agent, **options)
      end

      test "a recognized answer fills blanks and writes one applied row" do
        row = record(provider: "agent", citations: ["https://example.org/a"])

        assert_equal "books.book_facts", row.kind
        assert_equal "agent", row.mode
        assert_equal "applied", row.outcome
        assert row.recognized
        assert_equal "agent", row.provider
        assert_equal ["https://example.org/a"], row.citations
        assert_equal 1999, @book.reload.first_published_year
        assert row.facts["first_published_year"]["applied"]
      end

      test "an unrecognized answer applies nothing" do
        Services::Ai::Tasks::Books::DescriptionReviewTask.expects(:new).never

        row = record(facts(recognized: false))

        assert_equal "unrecognized", row.outcome
        assert row.facts.values.all? { |entry| entry["applied"] == false && entry["reason"] == "unrecognized" }
        assert_nil @book.reload.first_published_year
      end

      test "a low overall confidence is held under the given reason" do
        Services::Ai::Tasks::Books::DescriptionReviewTask.expects(:new).never

        row = record(facts(confidence: "low"), hold_low_confidence: "low_confidence")

        assert_equal "nothing_to_apply", row.outcome
        assert row.facts.values.all? { |entry| entry["reason"] == "low_confidence" }
        assert_nil @book.reload.first_published_year
      end

      test "a low overall confidence is applied when nothing holds it" do
        row = record(facts(confidence: "low"), hold_low_confidence: nil)

        assert_equal "applied", row.outcome
        assert_equal 1999, @book.reload.first_published_year
      end

      test "a held reason does not touch a medium answer" do
        row = record(facts(confidence: "medium"), hold_low_confidence: "deferred")

        assert_equal "applied", row.outcome
        assert_equal 1999, @book.reload.first_published_year
      end

      test "strict review raises before anything is written when the review call fails" do
        stub_review(spoilers: nil, style_violations: [], rewritten: nil, success: false)

        assert_no_difference -> { Enrichment.count } do
          assert_raises(RecordBookFacts::ReviewFailed) { record(strict_review: true) }
        end
        assert_nil @book.reload.first_published_year
        assert_empty @book.descriptions
      end

      test "strict review raises when the review succeeds but returns no spoilers verdict" do
        review = mock
        review.stubs(:call).returns(Services::Ai::Result.new(success: true, data: {}))
        Services::Ai::Tasks::Books::DescriptionReviewTask.stubs(:new).returns(review)

        assert_no_difference -> { Enrichment.count } do
          assert_raises(RecordBookFacts::ReviewFailed) { record(strict_review: true) }
        end
        assert_nil @book.reload.first_published_year
        assert_empty @book.descriptions
      end

      test "without strict review a failed review records review_failed and the other facts apply" do
        stub_review(spoilers: nil, style_violations: [], rewritten: nil, success: false)

        row = record

        assert_equal "review_failed", row.facts["description"]["reason"]
        assert_equal 1999, @book.reload.first_published_year
      end

      test "extra_facts are merged into every kind of row" do
        extra = {"context" => INPUT_ENTRY}

        applied = record(extra_facts: extra)
        unrecognized = record(facts(recognized: false), extra_facts: extra)
        held = record(facts(confidence: "low"), hold_low_confidence: "low_confidence", extra_facts: extra)

        [applied, unrecognized, held].each do |row|
          assert_equal INPUT_ENTRY, row.facts["context"]
        end
      end

      test "an agent row that recognized the book makes the dossier research-backed" do
        record

        assert Services::Books::Categorize::Dossier.build(book: @book).research_backed?
      end
    end
  end
end
