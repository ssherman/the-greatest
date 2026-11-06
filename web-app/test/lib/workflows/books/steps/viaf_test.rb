# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    module Steps
      class ViafTest < ActiveSupport::TestCase
        setup do
          @author = books_authors(:king)
          stub_workflow_dispatch
          # CI has no Redis: every call reserves its start time in a fake. The
          # clock is frozen so a second passing mid-reservation cannot shift a wait.
          freeze_time
          @schedule = ::Viaf::Schedule.new(redis: ::Books::OpenLibrary::FakeRedis.new)
          ::Viaf::Schedule.stubs(:new).returns(@schedule)
          @adapter = Viaf.new
          @adapter.stubs(:rand).returns(7)
        end

        def service_outcome(wikidata_qid: nil, needs_review: false)
          decision = stub(needs_review: needs_review)
          ::Services::Books::Authors::EnrichFromViaf::Result.new(success?: true,
            data: {outcome: :matched, wikidata_qid: wikidata_qid, decision: decision}, errors: [])
        end

        # in_line is the step's own memory of holding a place in the line.
        # start_at viaf plans the step ready, as the backfill does.
        def call(in_line: false, options: {})
          run = AuthorEnrichment.start(@author, initiated_by: "test", options: {start_at: "viaf"}.merge(options))
          step = run.step(:viaf)
          step.update!(result: {"in_line" => true}) if in_line
          @adapter.call(step: step, run: run, target: @author)
        end

        def stored_cluster(viaf_id)
          ExternalRecord.create!(source: :viaf, source_id: viaf_id, payload: {"viaf_id" => viaf_id, "name_type" => "Personal"},
            schema_version: ::Viaf::Distiller::SCHEMA_VERSION, fetched_at: Time.current)
        end

        test "an answer records the outcome, the QID, the review flag and whether the step was in line" do
          ::Services::Books::Authors::EnrichFromViaf.expects(:call).with(author: @author, refresh: true).returns(service_outcome(wikidata_qid: "Q7243"))

          result = call(options: {refresh: true})

          assert_equal [:succeeded, "matched", {"wikidata_qid" => "Q7243", "needs_review" => false, "in_line" => false}],
            [result.kind, result.outcome, result.result]
        end

        test "a decision that needs review is recorded as such" do
          ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(service_outcome(wikidata_qid: "Q7243", needs_review: true))

          assert_equal true, call.result["needs_review"]
        end

        test "no decision at all counts as not needing review" do
          ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(
            ::Services::Books::Authors::EnrichFromViaf::Result.new(success?: true, data: {outcome: :unmatched, wikidata_qid: nil, decision: nil}, errors: [])
          )

          assert_equal [false, nil], call.result.values_at("needs_review", "wikidata_qid")
        end

        test "a pause waits for a turn, releases the step at once, and joins the line" do
          ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))

          result = call

          assert_equal [:wait, 3607.seconds.from_now, true, {"in_line" => true}], [result.kind, result.run_after, result.release, result.result]
        end

        test "a busy pace before the first turn takes a turn within patience without releasing" do
          ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("VIAF pace busy", retry_after: 30))

          result = call

          assert_equal [37.seconds.from_now, false, {"in_line" => true}], [result.run_after, result.release, result.result]
        end

        test "a turn further than patience away releases the step" do
          ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("busy", retry_after: 30))
          @schedule.stubs(:reserve).returns(Viaf::CHAIN_PATIENCE + 1)

          result = call

          assert_equal [true, (Viaf::CHAIN_PATIENCE + 1 + 7).seconds.from_now], [result.release, result.run_after]
        end

        test "a busy pace on the step's own turn only delays the turn and keeps its place in the line" do
          ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("VIAF pace busy", retry_after: 30))

          result = call(in_line: true)

          assert_equal [37.seconds.from_now, false, {"in_line" => true}], [result.run_after, result.release, result.result]
          assert_nil @schedule.horizon
        end

        test "a pause on the step's own turn goes to the back of the line and releases" do
          2.times { @schedule.reserve(not_before: 30) }
          ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))

          result = call(in_line: true)

          assert_equal [3607.seconds.from_now, true], [result.run_after, result.release]
        end

        test "a step behind a waiting line joins it without asking VIAF" do
          @schedule.reserve(not_before: 30)
          ::Services::Books::Authors::EnrichFromViaf.expects(:call).never

          result = call

          assert_equal [(30 + 300 + 7).seconds.from_now, false, {"in_line" => true}], [result.run_after, result.release, result.result]
        end

        test "a far place in a waiting line releases the step" do
          8.times { @schedule.reserve(not_before: 30) }
          ::Services::Books::Authors::EnrichFromViaf.expects(:call).never

          result = call

          assert_equal [(30 + (8 * 300) + 7).seconds.from_now, true], [result.run_after, result.release]
        end

        test "a step already in line runs without consulting the line" do
          @schedule.reserve(not_before: 30)
          ::Services::Books::Authors::EnrichFromViaf.expects(:call).returns(service_outcome)

          result = call(in_line: true)

          assert_equal [:succeeded, true], [result.kind, result.result["in_line"]]
        end

        test "an author holding a VIAF id with a stored cluster skips the line" do
          @schedule.reserve(not_before: 30)
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "5391")
          stored_cluster("5391")
          ::Services::Books::Authors::EnrichFromViaf.expects(:call).with(author: @author, refresh: false).returns(service_outcome)

          assert_equal :succeeded, call.kind
        end

        test "an earlier era's decision that will put back a stored VIAF id skips the line" do
          @schedule.reserve(not_before: 30)
          ::MatchDecision.create!(finder: ::Services::Books::Authors::ResolveViaf.name, subject: @author, outcome: :matched, confidence: :high,
            decided_by: :ai, candidates: [{"external_key" => "5391"}], selected_index: 1, created_at: @author.created_at - 1.day)
          stored_cluster("5391")
          ::Services::Books::Authors::EnrichFromViaf.expects(:call).with(author: @author, refresh: false).returns(service_outcome)

          assert_equal :succeeded, call.kind
        end

        test "a forced run with a stored cluster still waits its turn" do
          @schedule.reserve(not_before: 30)
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "5391")
          stored_cluster("5391")
          ::Services::Books::Authors::EnrichFromViaf.expects(:call).never

          assert_equal :wait, call(options: {refresh: true}).kind
        end

        test "a held id with no stored cluster waits its turn" do
          @schedule.reserve(not_before: 30)
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "9999")
          ::Services::Books::Authors::EnrichFromViaf.expects(:call).never

          assert_equal :wait, call.kind
        end
      end
    end
  end
end
