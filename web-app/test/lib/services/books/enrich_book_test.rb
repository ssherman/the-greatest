require "test_helper"

module Services
  module Books
    class EnrichBookTest < ActiveSupport::TestCase
      def setup
        @book = ::Books::Book.create!(title: "A Fresh Book")
        @book.book_authors.create!(author: books_authors(:tolstoy), position: 1)
        @chat = AiChat.create!(parent: @book, chat_type: :analysis, model: "gpt-6-sol", provider: :openai)
        # Every run gets a clean description review unless a test says otherwise.
        stub_review(spoilers: false, style_violations: [], rewritten: nil)
      end

      CLEAN_DESCRIPTION = ("In a small Connecticut town, a young man takes a job caring for an elderly widow. " * 3).strip

      def facts(overrides = {})
        {
          recognized: true,
          confidence: "high",
          first_published_year: {value: 1999, confidence: "high"},
          first_published_year_estimated: false,
          original_language: {value: "en", confidence: "high"},
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

      def success_result(facts_hash, citations: [])
        Services::Ai::Result.new(success: true, data: {facts: facts_hash, citations: citations}, ai_chat: @chat)
      end

      def failure_result(message)
        Services::Ai::Result.new(success: false, error: message)
      end

      # Expects BookFactsTask to be built once per listed mode, in order, and
      # returns the given results.
      def expect_facts_runs(*runs)
        runs.each do |mode, result|
          task = mock
          task.stubs(:call).returns(result)
          Services::Ai::Tasks::Books::BookFactsTask.expects(:new)
            .with { |args| args[:parent] == @book && args[:mode] == mode }
            .returns(task)
        end
      end

      def stub_review(spoilers:, style_violations:, rewritten:, success: true)
        review = mock
        result = if success
          Services::Ai::Result.new(success: true, data: {spoilers: spoilers, spoiler_notes: nil, style_violations: style_violations, rewritten: rewritten}, ai_chat: @chat)
        else
          Services::Ai::Result.new(success: false, error: "review down")
        end
        review.stubs(:call).returns(result)
        Services::Ai::Tasks::Books::DescriptionReviewTask.stubs(:new).returns(review)
      end

      test "a recognized high-confidence knowledge run applies and writes one applied row" do
        expect_facts_runs([:knowledge, success_result(facts)])

        result = EnrichBook.call(book: @book)

        assert result.success?
        rows = result.data[:enrichments]
        assert_equal 1, rows.size
        row = rows.first
        assert row.knowledge?
        assert row.applied?
        assert_equal true, row.recognized
        assert row.confidence_high?
        assert_equal "books.book_facts", row.kind
        assert_equal @chat, row.ai_chat
        assert_equal "gpt-6-sol", row.model
        assert_equal "openai", row.provider
        assert_equal 1999, @book.reload.first_published_year
        assert_equal CLEAN_DESCRIPTION, @book.primary_description.content
        assert row.facts["description"]["applied"]
      end

      test "an unrecognized knowledge run applies nothing and falls back to research" do
        research_facts = facts(first_published_year: {value: 2001, confidence: "medium"}, confidence: "medium")
        expect_facts_runs(
          [:knowledge, success_result(facts(recognized: false, confidence: "low", first_published_year: {value: 1999, confidence: "low"}))],
          [:research, success_result(research_facts, citations: ["https://example.org/src"])]
        )

        result = EnrichBook.call(book: @book)

        assert result.success?
        knowledge, research = result.data[:enrichments]
        assert knowledge.unrecognized?
        assert_equal "unrecognized", knowledge.facts["first_published_year"]["reason"]
        refute knowledge.facts["first_published_year"]["applied"]
        assert research.research?
        assert research.applied?
        assert_equal ["https://example.org/src"], research.citations
        assert_equal 2001, @book.reload.first_published_year
        assert_equal "https://example.org/src", @book.descriptions.find_by(source: :ai_generated).source_url
      end

      test "a recognized but low-confidence run falls back to research" do
        expect_facts_runs(
          [:knowledge, success_result(facts(confidence: "low"))],
          [:research, success_result(facts(confidence: "high"))]
        )

        result = EnrichBook.call(book: @book)

        assert_equal %w[knowledge research], result.data[:enrichments].map(&:mode)
      end

      test "medium confidence does not trigger research" do
        expect_facts_runs([:knowledge, success_result(facts(confidence: "medium"))])

        result = EnrichBook.call(book: @book)

        assert_equal %w[knowledge], result.data[:enrichments].map(&:mode)
      end

      test "a book published at or after the cutoff skips the knowledge call" do
        @book.update!(first_published_year: Rails.application.config.x.ai.knowledge_cutoff_year)
        expect_facts_runs([:research, success_result(facts)])

        result = EnrichBook.call(book: @book)

        assert_equal %w[research], result.data[:enrichments].map(&:mode)
      end

      test "force_research goes straight to research" do
        expect_facts_runs([:research, success_result(facts)])

        EnrichBook.call(book: @book, force_research: true)
      end

      test "an exhausted research budget writes a skipped row instead of researching" do
        # A cap of zero is exhausted before the first research run.
        Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
        expect_facts_runs([:knowledge, success_result(facts(recognized: false, confidence: "low"))])

        result = EnrichBook.call(book: @book)

        assert result.success?
        knowledge, skipped = result.data[:enrichments]
        assert knowledge.unrecognized?
        assert skipped.skipped?
        assert skipped.research?
        assert_equal "budget_exhausted", skipped.reason
        assert_nil skipped.ai_chat
      end

      test "force_research ignores the budget" do
        Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
        expect_facts_runs([:research, success_result(facts)])

        result = EnrichBook.call(book: @book, force_research: true)

        assert_equal %w[research], result.data[:enrichments].map(&:mode)
      end

      test "a book at or past the cutoff skips research entirely when the daily budget is exhausted" do
        @book.update!(first_published_year: Rails.application.config.x.ai.knowledge_cutoff_year)
        Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
        Services::Ai::Tasks::Books::BookFactsTask.expects(:new).never

        result = EnrichBook.call(book: @book)

        assert result.success?
        rows = result.data[:enrichments]
        assert_equal 1, rows.size
        row = rows.first
        assert row.skipped?
        assert row.research?
        assert_equal "budget_exhausted", row.reason
      end

      test "a book with no author names is skipped as missing_inputs" do
        bare = ::Books::Book.create!(title: "Bare")
        Services::Ai::Tasks::Books::BookFactsTask.expects(:new).never

        result = EnrichBook.call(book: bare)

        assert result.success?
        row = result.data[:enrichments].first
        assert row.skipped?
        assert row.knowledge?
        assert_equal "missing_inputs", row.reason
      end

      test "passed author names satisfy the inputs check and reach the task" do
        bare = ::Books::Book.create!(title: "Bare")
        task = mock
        task.stubs(:call).returns(success_result(facts))
        Services::Ai::Tasks::Books::BookFactsTask.expects(:new)
          .with { |args| args[:parent] == bare && args[:author_names] == ["Someone"] }
          .returns(task)

        result = EnrichBook.call(book: bare, author_names: ["Someone"])

        assert result.data[:enrichments].first.applied?
      end

      test "a task failure writes a failed row and returns failure" do
        expect_facts_runs([:knowledge, failure_result("OpenAI timeout")])

        result = EnrichBook.call(book: @book)

        refute result.success?
        assert_equal ["OpenAI timeout"], result.errors
        row = result.data[:enrichments].first
        assert row.failed?
        assert_equal "OpenAI timeout", row.error
        assert_equal "gpt-6-sol", row.model
        assert_nil @book.reload.first_published_year
      end

      test "an empty model reply is a failed row, not a recognized run with nulls" do
        expect_facts_runs([:knowledge, success_result({})])

        result = EnrichBook.call(book: @book)

        refute result.success?
        assert_equal ["empty response"], result.errors
        row = result.data[:enrichments].first
        assert row.failed?
        assert_equal "empty response", row.error
      end

      test "a research failure after a good knowledge run keeps the knowledge row and reports failure" do
        expect_facts_runs(
          [:knowledge, success_result(facts(recognized: false, confidence: "low"))],
          [:research, failure_result("search down")]
        )

        result = EnrichBook.call(book: @book)

        refute result.success?
        assert_equal %w[unrecognized failed], result.data[:enrichments].map(&:outcome)
        assert_equal "gpt-6-astra", result.data[:enrichments].last.model
      end

      test "the reviewer's rewrite is what gets written, and the ledger says so" do
        rewritten = ("A young man in a small town cares for a widow who is losing her memory. " * 4).strip
        stub_review(spoilers: true, style_violations: ["em_dash"], rewritten: rewritten)
        expect_facts_runs([:knowledge, success_result(facts)])

        result = EnrichBook.call(book: @book)

        assert_equal rewritten, @book.reload.primary_description.content
        review = result.data[:enrichments].first.facts["description"]["review"]
        assert_equal true, review["spoilers"]
        assert_equal ["em_dash"], review["style_violations"]
        assert_equal true, review["rewritten"]
        assert_equal [], review["check_errors"]
      end

      test "a review that flags spoilers with no rewrite rejects the description" do
        stub_review(spoilers: true, style_violations: [], rewritten: nil)
        expect_facts_runs([:knowledge, success_result(facts)])

        result = EnrichBook.call(book: @book)

        row = result.data[:enrichments].first
        assert_equal "rejected", row.facts["description"]["reason"]
        assert_equal true, row.facts["description"]["review"]["spoilers"]
        assert_empty @book.reload.descriptions
      end

      test "an empty review reply is review_failed, other facts still apply" do
        review = mock
        review.stubs(:call).returns(Services::Ai::Result.new(success: true, data: {}, ai_chat: @chat))
        Services::Ai::Tasks::Books::DescriptionReviewTask.stubs(:new).returns(review)
        expect_facts_runs([:knowledge, success_result(facts)])

        result = EnrichBook.call(book: @book)

        row = result.data[:enrichments].first
        assert_equal "review_failed", row.facts["description"]["reason"]
        assert_empty @book.reload.descriptions
        assert row.applied?
        assert_equal 1999, @book.reload.first_published_year
      end

      test "a description that fails the deterministic check is rejected, other facts still apply" do
        expect_facts_runs([:knowledge, success_result(facts(description: {value: "Short — bad.", confidence: "high"}))])

        result = EnrichBook.call(book: @book)

        row = result.data[:enrichments].first
        assert row.applied?
        assert_equal "rejected", row.facts["description"]["reason"]
        assert_includes row.facts["description"]["review"]["check_errors"], "em_dash"
        assert_empty @book.reload.descriptions
        assert_equal 1999, @book.first_published_year
      end

      test "a failed review records review_failed and does not write the description" do
        stub_review(spoilers: false, style_violations: [], rewritten: nil, success: false)
        expect_facts_runs([:knowledge, success_result(facts)])

        result = EnrichBook.call(book: @book)

        row = result.data[:enrichments].first
        assert_equal "review_failed", row.facts["description"]["reason"]
        assert_empty @book.reload.descriptions
        assert row.applied?
      end

      test "a null description skips the review entirely" do
        Services::Ai::Tasks::Books::DescriptionReviewTask.expects(:new).never
        expect_facts_runs([:knowledge, success_result(facts(description: {value: nil, confidence: "low"}))])

        result = EnrichBook.call(book: @book)

        assert_equal "null", result.data[:enrichments].first.facts["description"]["reason"]
      end

      test "nothing_to_apply when every fact was already set" do
        @book.update!(first_published_year: 1950, original_language: languages(:english))
        @book.assign_description(source: :ai_generated, content: "Here.").save!
        expect_facts_runs([:knowledge, success_result(facts)])

        result = EnrichBook.call(book: @book)

        assert result.data[:enrichments].first.nothing_to_apply?
      end

      test "an unknown confidence string is stored as nil and does not break the run" do
        expect_facts_runs([:knowledge, success_result(facts(confidence: "certain"))])

        result = EnrichBook.call(book: @book)

        row = result.data[:enrichments].first
        assert_nil row.confidence
        assert row.applied?
      end

      test "a mixed-case confidence string is normalized and triggers the research fallback" do
        expect_facts_runs(
          [:knowledge, success_result(facts(confidence: "Low"))],
          [:research, success_result(facts(confidence: "high"))]
        )

        result = EnrichBook.call(book: @book)

        knowledge, research = result.data[:enrichments]
        assert knowledge.confidence_low?
        assert research.research?
      end

      test "an exception after a successful task write still leaves exactly one ledger row" do
        expect_facts_runs([:knowledge, success_result(facts)])
        ApplyBookFacts.stubs(:call).raises(ActiveRecord::RecordNotUnique.new("dup"))

        result = EnrichBook.call(book: @book)

        refute result.success?
        assert_equal ["dup"], result.errors
        row = result.data[:enrichments].first
        assert row.failed?
        assert_equal "dup", row.error
      end
    end
  end
end
