# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class EnrichAuthorTest < ActiveSupport::TestCase
        DESCRIPTION = ("Her poems and essays followed Paris between the wars, and she edited a small review that printed young writers. " * 3).strip
        LEAD = "Anna Brenner was a French poet and critic who wrote about Paris between the two world wars."
        # Shares "was a french poet and critic who wrote about paris" with LEAD.
        COPYING = "#{DESCRIPTION} She was a French poet and critic who wrote about Paris."
        REWRITE = ("She wrote poems and criticism about Paris in the years between two wars and ran a small review. " * 3).strip

        def setup
          @author = ::Books::Author.create!(name: "Anna Brenner")
          @chat = AiChat.create!(parent: @author, chat_type: :analysis, model: "gpt-6-sol", provider: :openai)
          stub_records(matched: false)
          stub_review(style_violations: [], rewritten: nil)
        end

        def stub_records(matched:, lead: nil)
          wikidata = matched ? MatchedRecords::Match.new(source_id: "Q1", evidence: {}) : nil
          page = lead && ::Wikipedia::Lead.new(language: "en", page_id: 9, title: "Anna Brenner",
            url: "https://en.wikipedia.org/wiki/Anna_Brenner", extract: lead, wikibase_item: "Q1", disambiguation: false)
          sources = matched ? [{"source" => "wikidata", "source_id" => "Q1"}] : []
          @records = stub(wikidata: wikidata, viaf: nil, lead: page, matched?: matched, sources: sources)
          MatchedRecords.stubs(:new).returns(@records)
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

        def success_result(facts_hash, citations: [])
          ::Services::Ai::Result.new(success: true, data: {facts: facts_hash, citations: citations}, ai_chat: @chat)
        end

        def failure_result(message) = ::Services::Ai::Result.new(success: false, error: message)

        # Expects AuthorFactsTask to be built once per listed mode, with the
        # author and its matched records, and returns the given results.
        def expect_runs(*runs)
          runs.each do |mode, result|
            task = mock
            task.stubs(:call).returns(result)
            ::Services::Ai::Tasks::Books::AuthorFactsTask.expects(:new)
              .with { |args| args[:parent] == @author && args[:mode] == mode && args[:records] == @records }
              .returns(task)
          end
        end

        def review_result(style_violations:, rewritten:)
          ::Services::Ai::Result.new(success: true, data: {style_violations: style_violations, rewritten: rewritten}, ai_chat: @chat)
        end

        def stub_review(style_violations:, rewritten:, success: true)
          review = mock
          review.stubs(:call).returns(success ? review_result(style_violations: style_violations, rewritten: rewritten) :
            ::Services::Ai::Result.new(success: false, error: "review down"))
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.stubs(:new).returns(review)
        end

        def rows = @author.enrichments.for_kind(EnrichAuthor::KIND).order(:id)

        test "a placeholder author is skipped without a model call" do
          ::Services::Ai::Tasks::Books::AuthorFactsTask.expects(:new).never
          author = books_authors(:excluded_placeholder)

          result = EnrichAuthor.call(author: author)

          assert result.success?
          assert_equal [["skipped", "placeholder"]], author.enrichments.for_kind(EnrichAuthor::KIND).pluck(:outcome, :reason)
        end

        test "an author with nothing left to fill is skipped" do
          ::Services::Ai::Tasks::Books::AuthorFactsTask.expects(:new).never
          @author.update!(birth_year: 1901, gender: :female)
          @author.author_countries.create!(country: books_countries(:french))
          @author.assign_description(source: :manual, content: "Written by hand.")
          @author.save!

          EnrichAuthor.call(author: @author)

          assert_equal [["skipped", "complete"]], rows.pluck(:outcome, :reason)
        end

        test "an unspecified gender leaves the author incomplete" do
          @author.update!(birth_year: 1901, gender: :unspecified)
          @author.author_countries.create!(country: books_countries(:french))
          @author.assign_description(source: :ai_generated, content: "Written before.")
          @author.save!
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal "female", @author.reload.gender
        end

        test "a recognized knowledge run applies and writes one row naming its sources" do
          stub_records(matched: true)
          expect_runs([:knowledge, success_result(facts)])

          result = EnrichAuthor.call(author: @author)

          assert result.success?
          row = rows.sole
          assert_equal ["books.author_facts", "knowledge", "applied", true, "high"], [row.kind, row.mode, row.outcome, row.recognized, row.confidence]
          assert_equal [@chat, "gpt-6-sol", "openai"], [row.ai_chat, row.model, row.provider]
          assert_equal({"value" => [{"source" => "wikidata", "source_id" => "Q1"}], "applied" => false, "reason" => "input"}, row.facts["sources"])
          assert_equal [1901, DESCRIPTION], [@author.reload.birth_year, @author.descriptions.sole.content]
        end

        test "an unmatched author the model does not know is researched" do
          expect_runs([:knowledge, success_result(facts(recognized: false))], [:research, success_result(facts(confidence: "medium"))])

          result = EnrichAuthor.call(author: @author)

          assert_equal [%w[knowledge unrecognized], %w[research applied]], rows.pluck(:mode, :outcome)
          assert_equal "unrecognized", rows.first.facts["birth_year"]["reason"]
          assert_equal 1901, @author.reload.birth_year
          assert_equal 2, result.data[:enrichments].size
        end

        test "an author an authority matched is never researched" do
          stub_records(matched: true)
          expect_runs([:knowledge, success_result(facts(recognized: false))])

          EnrichAuthor.call(author: @author)

          assert_equal [%w[knowledge unrecognized]], rows.pluck(:mode, :outcome)
        end

        test "allow_research false never researches" do
          expect_runs([:knowledge, success_result(facts(recognized: false))])

          EnrichAuthor.call(author: @author, allow_research: false)

          assert_equal [%w[knowledge unrecognized]], rows.pluck(:mode, :outcome)
        end

        test "an exhausted research budget writes a skipped research row" do
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
          expect_runs([:knowledge, success_result(facts(recognized: false))])

          EnrichAuthor.call(author: @author)

          assert_equal [%w[knowledge unrecognized], %w[research skipped]], rows.pluck(:mode, :outcome)
          assert_equal "budget_exhausted", rows.last.reason
        end

        test "a low-confidence knowledge answer is deferred to research, which applies" do
          expect_runs([:knowledge, success_result(facts(confidence: "low"))], [:research, success_result(facts)])

          EnrichAuthor.call(author: @author)

          deferred, researched = rows.to_a
          assert_equal ["nothing_to_apply", "deferred"], [deferred.outcome, deferred.facts["birth_year"]["reason"]]
          assert_equal "deferred", deferred.facts["countries"]["reason"]
          assert_equal "applied", researched.outcome
          assert_equal 1901, @author.reload.birth_year
        end

        test "a low-confidence answer about a matched author applies what it is sure of" do
          stub_records(matched: true)
          expect_runs([:knowledge, success_result(facts(confidence: "low", birth_year: {confidence: "low"}))])

          EnrichAuthor.call(author: @author)

          row = rows.sole
          assert_equal ["applied", "low_confidence"], [row.outcome, row.facts["birth_year"]["reason"]]
          assert_equal "female", @author.reload.gender
          assert_nil @author.birth_year
        end

        test "a low-confidence answer is applied when research is not allowed" do
          expect_runs([:knowledge, success_result(facts(confidence: "low"))])

          EnrichAuthor.call(author: @author, allow_research: false)

          assert_equal [%w[knowledge applied]], rows.pluck(:mode, :outcome)
          assert_equal 1901, @author.reload.birth_year
        end

        test "a low-confidence answer is applied when the research budget is gone" do
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
          expect_runs([:knowledge, success_result(facts(confidence: "low"))])

          EnrichAuthor.call(author: @author)

          assert_equal [%w[knowledge applied], %w[research skipped]], rows.pluck(:mode, :outcome)
          assert_equal "budget_exhausted", rows.last.reason
          assert_equal 1901, @author.reload.birth_year
        end

        test "a failed task writes a failed row on the standard role and does not research" do
          expect_runs([:knowledge, failure_result("timeout")])

          result = EnrichAuthor.call(author: @author)

          refute result.success?
          assert_equal ["timeout"], result.errors
          row = rows.sole
          assert_equal ["failed", "timeout", "gpt-6-sol", "openai"], [row.outcome, row.error, row.model, row.provider]
        end

        test "an empty answer is a failure" do
          expect_runs([:knowledge, success_result({})])

          refute EnrichAuthor.call(author: @author).success?
          assert_equal "empty response", rows.sole.error
        end

        test "an error while applying still leaves one failed row" do
          expect_runs([:knowledge, success_result(facts)])
          ApplyAuthorFacts.stubs(:call).raises(StandardError, "boom")

          EnrichAuthor.call(author: @author)

          assert_equal [["failed", "boom"]], rows.pluck(:outcome, :error)
        end

        test "the reviewer sees the draft, the lead and the code's findings; a clean draft is written" do
          stub_records(matched: true, lead: LEAD)
          review = mock
          review.stubs(:call).returns(review_result(style_violations: [], rewritten: nil))
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.expects(:new)
            .with { |args| args[:parent] == @author && args[:description] == DESCRIPTION && args[:source_text] == LEAD && args[:flagged] == [] }
            .returns(review)
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal DESCRIPTION, @author.reload.descriptions.sole.content
        end

        test "a draft that copies the lead goes to the reviewer flagged, and its clean rewrite is written" do
          stub_records(matched: true, lead: LEAD)
          review = mock
          review.stubs(:call).returns(review_result(style_violations: ["copied_phrasing"], rewritten: REWRITE))
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.expects(:new).with { |args| args[:flagged] == ["copied"] }.returns(review)
          expect_runs([:knowledge, success_result(facts(description: {value: COPYING}))])

          EnrichAuthor.call(author: @author)

          assert_equal REWRITE, @author.reload.descriptions.sole.content
          assert_equal ["copied"], rows.sole.facts["description"]["review"]["check_errors"]
        end

        test "a rewrite that still copies the lead is rejected" do
          stub_records(matched: true, lead: LEAD)
          stub_review(style_violations: ["copied_phrasing"], rewritten: COPYING)
          expect_runs([:knowledge, success_result(facts(description: {value: COPYING}))])

          EnrichAuthor.call(author: @author)

          assert_equal ["rejected", false], rows.sole.facts["description"].values_at("reason", "applied")
          assert_equal 0, @author.reload.descriptions.count
        end

        test "violations with no rewrite are rejected" do
          stub_review(style_violations: ["names_author_at_start"], rewritten: nil)
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal "rejected", rows.sole.facts["description"]["reason"]
        end

        test "a failed or empty review keeps the description out" do
          stub_review(style_violations: [], rewritten: nil, success: false)
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal "review_failed", rows.sole.facts["description"]["reason"]

          empty = mock
          empty.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {}, ai_chat: @chat))
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.stubs(:new).returns(empty)
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal "review_failed", rows.last.facts["description"]["reason"]
        end

        test "an author with an AI description keeps it and the review is skipped" do
          @author.assign_description(source: :ai_generated, content: "Written before.")
          @author.save!
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.expects(:new).never
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal "already_set", rows.sole.facts["description"]["reason"]
          assert_equal "Written before.", @author.reload.descriptions.sole.content
        end

        # Ruling: the author's own work titles, and those the matched records
        # list, are exempt from the copy check (spec §9 requires naming
        # best-known works plainly, so a shared long title is not a copy).
        # Without the exemption this draft is flagged ["copied"] because the
        # title alone shares 9 consecutive words with the lead.
        test "a long title the lead also names is not a copy" do
          book = ::Books::Book.create!(title: "The Man Who Mistook His Wife for a Hat")
          book.book_authors.create!(author: @author, position: 1)
          lead = "Anna Brenner is best known for The Man Who Mistook His Wife for a Hat, a collection of essays."
          stub_records(matched: true, lead: lead)
          review = mock
          review.stubs(:call).returns(review_result(style_violations: [], rewritten: nil))
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.expects(:new)
            .with { |args| args[:flagged] == [] }
            .returns(review)
          description = "#{DESCRIPTION} Her book The Man Who Mistook His Wife for a Hat gathers case histories."
          expect_runs([:knowledge, success_result(facts(description: {value: description}))])

          EnrichAuthor.call(author: @author)

          assert_equal description, @author.reload.descriptions.sole.content
        end

        # Ruling: ApplyAuthorFacts never writes a low-confidence fact, so
        # reviewing its description would waste a fast-role call.
        test "a low-confidence description is not reviewed" do
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.expects(:new).never
          expect_runs([:knowledge, success_result(facts(description: {confidence: "low"}))])

          EnrichAuthor.call(author: @author)

          assert_equal "low_confidence", rows.sole.facts["description"]["reason"]
          assert_equal 0, @author.reload.descriptions.count
        end
      end
    end
  end
end
