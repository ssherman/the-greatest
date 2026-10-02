# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class EnrichFromViafTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Stacy Willingham", birth_year: 1991)
          @person = viaf_person("5391", headings: ["Willingham, Stacy"], born: "1991", gender: "a", wikidata: "Q115493575")
          @client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]},
            people: {"5391" => @person}
          )
        end

        def run_viaf(refresh: false, client: @client) = EnrichFromViaf.call(author: @author, refresh: refresh, client: client)

        def rows = @author.enrichments.for_kind(EnrichFromViaf::KIND).order(:id)

        test "a match applies the cluster and writes one applied row tied to the decision" do
          result = run_viaf

          row = rows.sole
          assert_equal ["applied", "viaf", true, "high"], [row.outcome, row.provider, row.recognized, row.confidence]
          assert_equal result.data[:decision], row.match_decision
          assert_equal ["https://viaf.org/viaf/5391"], row.citations
          assert_equal "filled", row.facts["gender"]["reason"]
          assert_equal ["female", "Q115493575"], [@author.reload.gender, result.data[:wikidata_qid]]
        end

        test "no match writes an unrecognized row" do
          result = run_viaf(client: FakeViafClient.new)

          assert_equal [:unmatched, "unrecognized", false], [result.data[:outcome], rows.sole.outcome, rows.sole.recognized]
          assert_nil result.data[:wikidata_qid]
        end

        # The held cluster is someone else, so the search matches by rule at
        # high confidence (no review) and only the conflict flags it.
        test "an author holding a different VIAF id applies nothing and flags the decision" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "999")
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]},
            people: {"5391" => @person, "999" => viaf_person("999", headings: ["Else, Someone"])}
          )

          result = run_viaf(client: client)

          assert_equal ["nothing_to_apply", "held_viaf_conflict"], [rows.last.outcome, rows.last.reason]
          assert_equal "high", result.data[:decision].confidence
          assert result.data[:decision].reload.needs_review
          assert_nil @author.reload.gender
        end

        test "an already processed author is skipped without asking VIAF; refresh runs it again" do
          @author.enrichments.create!(kind: EnrichFromViaf::KIND, outcome: :unrecognized, reason: "no_match")

          assert_equal ["skipped", "already_processed"], [run_viaf.data[:enrichment].outcome, rows.last.reason]
          assert_empty @client.calls

          run_viaf(refresh: true)
          assert_equal "applied", rows.last.outcome
        end

        test "a failed or skipped row, or one older than the author row, does not count as processed" do
          @author.enrichments.create!(kind: EnrichFromViaf::KIND, outcome: :failed, error: "boom")
          @author.enrichments.create!(kind: EnrichFromViaf::KIND, outcome: :skipped, reason: "placeholder")
          @author.enrichments.create!(kind: EnrichFromViaf::KIND, outcome: :applied, created_at: 2.days.ago)

          assert_equal :matched, run_viaf.data[:outcome]
        end

        test "a placeholder author is skipped without asking VIAF" do
          @author.update!(exclude_from_rankings: true)

          assert_equal ["skipped", "placeholder"], [run_viaf.data[:enrichment].outcome, rows.sole.reason]
          assert_empty @client.calls
        end

        test "a failed AI selection writes a failed row tied to its decision" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "S. Willingham")]}, people: {"5391" => @person})
          task = mock("task")
          task.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "timeout"))
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).returns(task)

          result = run_viaf(client: client)

          assert_equal ["failed", "resolve_failed"], [rows.sole.outcome, rows.sole.reason]
          assert_equal result.data[:decision], rows.sole.match_decision
          assert_not result.success?
        end

        test "a VIAF error writes a failed row and returns" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => ::Viaf::Exceptions::ServerError.new("Server error: 503", 503)})

          result = run_viaf(client: client)

          assert_equal ["failed", "viaf_error"], [rows.sole.outcome, rows.sole.reason]
          assert_match(/ServerError/, rows.sole.error)
          assert_not result.success?
        end

        test "a forced run reads every cluster with refresh true" do
          run_viaf(refresh: true)

          assert_equal [true], @client.refreshes
        end

        test "an ordinary run reads every cluster with refresh false" do
          run_viaf

          assert_equal [false], @client.refreshes
        end

        test "a run whose decision a person rejected does not count as processed" do
          decision = ::MatchDecision.create!(finder: ResolveViaf.name, subject: @author, outcome: :matched, confidence: :high,
            decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => "5391"}], selected_index: 1)
          @author.enrichments.create!(kind: EnrichFromViaf::KIND, outcome: :applied, reason: "matched 5391", match_decision: decision)

          result = EnrichFromViaf.call(author: @author, client: FakeViafClient.new)

          assert_equal :unmatched, result.data[:outcome]
        end

        test "a rate limit propagates and writes nothing, so the rescheduled run starts clean" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => ::Viaf::Exceptions::RateLimited.new("wait", retry_after: 60)})

          assert_raises(::Viaf::Exceptions::RateLimited) { run_viaf(client: client) }
          assert_empty rows
        end
      end
    end
  end
end
