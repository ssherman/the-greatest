# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class BackfillReportTest < ActiveSupport::TestCase
        def setup
          QueuedChain.stubs(:by_job).returns({"Books::Authors::ViafJob" => [1, 2]})
          # Built before stubbing: once `stubs(:new)` installs the stub,
          # Viaf::Schedule.new would itself be intercepted (returning nil,
          # since no return value is set yet) if constructed inline inside
          # the `.returns(...)` argument.
          schedule = ::Viaf::Schedule.new(redis: ::Books::OpenLibrary::FakeRedis.new)
          ::Viaf::Schedule.stubs(:new).returns(schedule)
          @since = Time.current
          travel 1.second
          @author = ::Books::Author.create!(name: "Report Author")
          @other = ::Books::Author.create!(name: "Report Other")
        end

        def decide(finder, outcome, decided_by, needs_review: false, at: Time.current, subject: @author)
          ::MatchDecision.create!(finder: finder.name, subject: subject, outcome: outcome, confidence: :high, decided_by: decided_by,
            needs_review: needs_review, candidates: [], created_at: at)
        end

        def ledger(author, kind, outcome, recognized: nil, reason: nil, at: Time.current)
          author.enrichments.create!(kind: kind, outcome: outcome, recognized: recognized, reason: reason, created_at: at)
        end

        def chat(model, input:, output:, web_searches: 0)
          AiChat.create!(parent: @author, model: model, provider: :openai, chat_type: :analysis,
            raw_responses: [{"usage" => {"input_tokens" => input, "output_tokens" => output}, "web_search_calls" => web_searches}])
        end

        def report = BackfillReport.call(since: @since).data

        test "splits each step's decisions by outcome and how they were decided, and counts those needing review, " \
          "by each author's latest decision" do
          third = ::Books::Author.create!(name: "Report Third")

          # @author's Wikidata step ran twice in the window (a retry): only the later decision should count.
          decide(ResolveWikidata, :unmatched, :ai, needs_review: true, at: @since + 10.minutes)
          decide(ResolveWikidata, :matched, :identifier, at: @since + 20.minutes)

          # @other's latest Wikidata decision is flagged, but already reviewed: it must not count as needing review.
          reviewed = decide(ResolveWikidata, :unmatched, :ai, needs_review: true, at: @since + 5.minutes, subject: @other)
          reviewed.update!(reviewed_at: Time.current)

          # third: a single VIAF decision, and a Wikidata decision entirely before the window (must not leak in).
          decide(ResolveViaf, :matched, :identifier, subject: third)
          decide(ResolveWikidata, :matched, :identifier, at: @since - 1.hour, subject: third)

          data = report

          assert_equal({"matched identifier" => 1, "unmatched ai" => 1}, data[:decisions]["Wikidata"][:split])
          assert_equal [0, 0], [data[:decisions]["Wikidata"][:needs_review], data[:decisions]["VIAF"][:needs_review]]
          assert_equal({"matched identifier" => 1}, data[:decisions]["VIAF"][:split])
        end

        test "counts the authors the Wikidata step ran and matched, and the ledger outcomes with failure reasons" do
          ledger(@author, EnrichFromWikidata::KIND, :applied, recognized: true, at: Time.current)
          ledger(@other, EnrichFromWikidata::KIND, :unrecognized, recognized: false, at: Time.current + 1.hour)
          ledger(@other, EnrichFromViaf::KIND, :failed, reason: "viaf_error")

          data = report

          assert_equal [2, 1], data.values_at(:authors, :matched)
          assert_in_delta 2.0, data[:per_hour], 0.01
          assert_equal({"applied" => 1, "unrecognized" => 1}, data[:outcomes][EnrichFromWikidata::KIND])
          assert_equal({"viaf_error" => 1}, data[:failures][EnrichFromViaf::KIND])
        end

        test "adds up the AI calls' tokens and prices them per model" do
          chat("gpt-6-sol", input: 1_000_000, output: 100_000)
          chat("gpt-6-astra", input: 0, output: 0, web_searches: 3)
          chat("unpriced-model", input: 10, output: 10)

          ai = report[:ai]

          assert_equal({chats: 1, input: 1_000_000, output: 100_000, web_searches: 0, cost: 3.0}, ai[:by_model]["gpt-6-sol"])
          assert_in_delta 0.03, ai[:by_model]["gpt-6-astra"][:cost], 0.0001
          assert_nil ai[:by_model]["unpriced-model"][:cost]
          assert_in_delta 3.03, ai[:cost], 0.0001
        end

        test "reports what is still waiting and what remains, and says it all in lines" do
          data = report

          assert_equal({"Books::Authors::ViafJob" => 2}, data[:waiting])
          assert_operator data[:remaining], :>=, 2
          assert(data[:lines].any? { |line| line.include?("list prices") })
          assert(data[:lines].any? { |line| line.include?("flex") })
        end
      end
    end
  end
end
