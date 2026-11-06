# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    class AuthorEnrichmentTest < ActiveSupport::TestCase
      WIKIDATA = ::Services::Books::Authors::EnrichFromWikidata
      VIAF = ::Services::Books::Authors::EnrichFromViaf

      setup do
        @author = books_authors(:king)
        # Plans without running: each test drives the steps it cares about.
        stub_workflow_dispatch
        # CI has no Redis: the VIAF line lives in a fake.
        @schedule = ::Viaf::Schedule.new(redis: ::Books::OpenLibrary::FakeRedis.new)
        ::Viaf::Schedule.stubs(:new).returns(@schedule)
        ::Books::Authors::EnrichJob.stubs(:hand_off)
        ::Services::Books::Authors::EnrichAuthor.stubs(:call).returns(stub(success?: true, errors: []))
      end

      def wikidata_result(value)
        WIKIDATA::Result.new(success?: value != :failed, data: {outcome: value}, errors: [])
      end

      def viaf_result(outcome: :matched, wikidata_qid: nil, needs_review: false)
        VIAF::Result.new(success?: true,
          data: {outcome: outcome, wikidata_qid: wikidata_qid, decision: stub(needs_review: needs_review)}, errors: [])
      end

      # The first Wikidata call is the chain's own; the forced one after VIAF
      # (refresh: true) answers with via_viaf.
      def stub_services(wikidata: nil, via_viaf: :matched, viaf: nil)
        WIKIDATA.stubs(:call).with { |author:, refresh:| !refresh }.returns(wikidata_result(wikidata)) if wikidata
        WIKIDATA.stubs(:call).with { |author:, refresh:| refresh }.returns(wikidata_result(via_viaf))
        VIAF.stubs(:call).returns(viaf_result(**viaf)) if viaf
      end

      def start(options: {})
        AuthorEnrichment.start(@author, initiated_by: "test", options: options)
      end

      def run_step(run, key)
        step = run.step(key)
        assert step.ready?, "#{key} is #{step.state}, not ready"
        WorkflowStepJob.new.tap { it.jid = "test-#{key}-#{SecureRandom.hex(3)}" }.perform(step.id)
      end

      # A waiting step whose time came: the sweep readies it.
      def wake(run, key)
        run.step(key).update_columns(run_after: 1.minute.ago)
        Workflows::Recovery.call
      end

      def states(run, *keys)
        keys.map { |key| run.step(key).state }
      end

      test "is registered as books.author_enrichment version 1 on authors, with its five steps in order" do
        assert_equal [AuthorEnrichment, "books.author_enrichment", 1, ::Books::Author], [
          Workflows::Registry.fetch("books.author_enrichment"), AuthorEnrichment.workflow, AuthorEnrichment.version, AuthorEnrichment.target_class
        ]
        assert_equal %i[wikidata viaf wikidata_via_viaf author_facts author_facts_late], AuthorEnrichment.steps.map(&:key)
        assert_equal [:author_chain], AuthorEnrichment.steps.map(&:queue).uniq
      end

      test "start plans a running run and dispatches the ready steps after commit" do
        Workflows::Dispatcher.unstub(:dispatch)
        Workflows::Dispatcher.expects(:dispatch).with { |steps| steps.map(&:key) == ["wikidata"] }

        run = start

        assert_equal ["books.author_enrichment", "running", "test"], [run.workflow, run.status, run.initiated_by]
        assert_equal %w[ready blocked blocked blocked blocked], run.steps.order(:id).map(&:state)
      end

      test "start raises for options the planner refuses" do
        assert_raises(ArgumentError) { start(options: {start_at: "nonsense"}) }
      end

      test "a Wikidata match skips VIAF and its follow-up, then runs the AI step" do
        stub_services(wikidata: :matched)
        run = start
        run_step(run, :wikidata)

        assert_equal %w[skipped skipped ready], states(run, :viaf, :wikidata_via_viaf, :author_facts)
        assert_equal ["not_needed", "not_needed"], [run.step(:viaf).outcome, run.step(:wikidata_via_viaf).outcome]
      end

      test "a failed Wikidata outcome also skips VIAF: the chain goes on as it does today" do
        stub_services(wikidata: :failed)
        run = start
        run_step(run, :wikidata)

        assert_equal %w[skipped ready], states(run, :viaf, :author_facts)
      end

      test "a Wikidata miss runs VIAF, which holds the AI step back" do
        stub_services(wikidata: :unmatched)
        run = start
        run_step(run, :wikidata)

        assert_equal %w[ready blocked blocked], states(run, :viaf, :wikidata_via_viaf, :author_facts)
      end

      test "VIAF within patience: the follow-up finishes before the AI step, and the late step is skipped" do
        stub_services(wikidata: :unmatched, viaf: {outcome: :matched, wikidata_qid: "Q1"})
        run = start
        %i[wikidata viaf wikidata_via_viaf author_facts].each { run_step(run, it) }

        assert_equal %w[succeeded skipped completed], [run.step(:author_facts).state, run.step(:author_facts_late).state, run.reload.status]
        assert_equal "not_needed", run.step(:author_facts_late).outcome
      end

      test "VIAF without a QID skips the follow-up and frees the AI step" do
        stub_services(wikidata: :unmatched, viaf: {outcome: :unmatched})
        run = start
        %i[wikidata viaf].each { run_step(run, it) }

        assert_equal %w[skipped ready], states(run, :wikidata_via_viaf, :author_facts)
      end

      test "a VIAF QID that needs review is not sent back to Wikidata" do
        stub_services(wikidata: :unmatched, viaf: {outcome: :matched, wikidata_qid: "Q1", needs_review: true})
        run = start
        %i[wikidata viaf].each { run_step(run, it) }

        assert_equal %w[skipped ready], states(run, :wikidata_via_viaf, :author_facts)
      end

      test "the follow-up Wikidata run is forced, and the AI step sees its facts first" do
        stub_services(wikidata: :unmatched, viaf: {wikidata_qid: "Q1"})
        run = start
        %i[wikidata viaf].each { run_step(run, it) }
        WIKIDATA.expects(:call).with(author: @author, refresh: true).returns(wikidata_result(:matched))

        assert_equal "blocked", run.step(:author_facts).reload.state
        run_step(run, :wikidata_via_viaf)

        assert_equal "ready", run.step(:author_facts).reload.state
      end

      test "VIAF beyond patience releases the AI step now; a late QID runs the follow-up and the late AI step" do
        stub_services(wikidata: :unmatched)
        VIAF.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("busy", retry_after: 30))
        @schedule.stubs(:reserve).returns(Steps::Viaf::CHAIN_PATIENCE + 1)
        run = start
        run_step(run, :wikidata)
        run_step(run, :viaf)

        assert_equal ["waiting", true, "ready"], [run.step(:viaf).reload.state, run.step(:viaf).released?, run.step(:author_facts).reload.state]
        run_step(run, :author_facts)

        VIAF.stubs(:call).returns(viaf_result(wikidata_qid: "Q1"))
        wake(run, :viaf)
        run_step(run, :viaf)
        assert_equal "ready", run.step(:wikidata_via_viaf).reload.state
        run_step(run, :wikidata_via_viaf)

        assert_equal "ready", run.step(:author_facts_late).reload.state
        run_step(run, :author_facts_late)
        assert_equal ["completed", "succeeded"], [run.reload.status, run.step(:author_facts_late).state]
      end

      test "a late VIAF answer with no QID skips the follow-up and the late AI step" do
        stub_services(wikidata: :unmatched)
        VIAF.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))
        run = start
        run_step(run, :wikidata)
        run_step(run, :viaf)
        run_step(run, :author_facts)

        VIAF.stubs(:call).returns(viaf_result(outcome: :unmatched))
        wake(run, :viaf)
        run_step(run, :viaf)

        assert_equal %w[skipped skipped completed], [*states(run, :wikidata_via_viaf, :author_facts_late), run.reload.status]
      end

      test "start_at viaf runs VIAF for an author Wikidata already processed" do
        run = start(options: {start_at: "viaf"})

        assert_equal ["skipped", "not_requested", "ready"], [run.step(:wikidata).state, run.step(:wikidata).outcome, run.step(:viaf).state]
      end

      test "start_at viaf with a QID still goes on to the follow-up" do
        stub_services(viaf: {wikidata_qid: "Q1"})
        run = start(options: {start_at: "viaf"})
        run_step(run, :viaf)

        assert_equal "ready", run.step(:wikidata_via_viaf).reload.state
      end

      test "skip_ai_if_ran skips the AI step when it already ran this era" do
        ::Services::Books::Authors::LedgerRun.stubs(:ai_step_ran_ids).returns(Set[@author.id])
        stub_services(wikidata: :matched)
        run = start(options: {skip_ai_if_ran: true})
        run_step(run, :wikidata)

        assert_equal ["skipped", "already_ran"], [run.step(:author_facts).reload.state, run.step(:author_facts).outcome]
      end

      test "skip_ai_if_ran runs the AI step when it has not run" do
        ::Services::Books::Authors::LedgerRun.stubs(:ai_step_ran_ids).returns(Set.new)
        stub_services(wikidata: :matched)
        run = start(options: {skip_ai_if_ran: true})
        run_step(run, :wikidata)

        assert_equal "ready", run.step(:author_facts).reload.state
      end

      test "without skip_ai_if_ran the ledger is not consulted" do
        ::Services::Books::Authors::LedgerRun.expects(:ai_step_ran_ids).never
        stub_services(wikidata: :matched)
        run = start
        run_step(run, :wikidata)

        assert_equal "ready", run.step(:author_facts).reload.state
      end

      test "a skipped AI step still lets the late one run after a late QID" do
        ::Services::Books::Authors::LedgerRun.stubs(:ai_step_ran_ids).returns(Set[@author.id])
        run = start(options: {start_at: "viaf", skip_ai_if_ran: true})
        VIAF.stubs(:call).returns(viaf_result(wikidata_qid: "Q1"))
        stub_services
        run_step(run, :viaf)
        run_step(run, :wikidata_via_viaf)

        assert_equal ["skipped", "ready"], states(run, :author_facts, :author_facts_late)
      end

      test "a Wikidata rate limit waits without counting an attempt" do
        WIKIDATA.stubs(:call).raises(::Wikimedia::Exceptions::RateLimited.new("busy", retry_after: 60))
        run = start
        run_step(run, :wikidata)

        assert_equal ["waiting", 0], [run.step(:wikidata).reload.state, run.step(:wikidata).attempts]
      end

      test "the AI step still releases after its retries are exhausted, and hands legacy books on" do
        ::Services::Books::Authors::EnrichAuthor.stubs(:call).returns(stub(success?: false, errors: ["x"]))
        ::Books::Authors::EnrichJob.expects(:hand_off).with(@author.id).once
        stub_services(wikidata: :matched)
        run = start
        run_step(run, :wikidata)
        3.times do |attempt|
          run_step(run, :author_facts)
          wake(run, :author_facts) if attempt < 2
        end

        assert_equal ["failed", true, 3], [run.step(:author_facts).reload.state, run.step(:author_facts).released?, run.step(:author_facts).attempts]
        assert_equal ["skipped", "completed_with_failures"], [run.step(:author_facts_late).state, run.reload.status]
      end

      test "a successful AI step hands legacy books on once" do
        ::Books::Authors::EnrichJob.expects(:hand_off).with(@author.id).once
        stub_services(wikidata: :matched)
        run = start
        run_step(run, :wikidata)
        run_step(run, :author_facts)
      end

      test "a late VIAF QID that lands while the AI step is still running still gets a late AI pass" do
        stub_services(wikidata: :unmatched)
        VIAF.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))
        run = start
        run_step(run, :wikidata)
        run_step(run, :viaf)
        # The AI step is claimed and running (a long research call) ...
        facts = Workflows::Coordinator.claim(run.step(:author_facts).id, token: "long-call")
        assert_equal "running", facts.state

        # ... when VIAF's turn comes, answers with a QID, and the follow-up finishes.
        VIAF.stubs(:call).returns(viaf_result(wikidata_qid: "Q1"))
        wake(run, :viaf)
        run_step(run, :viaf)
        run_step(run, :wikidata_via_viaf)
        assert_equal "blocked", run.step(:author_facts_late).reload.state

        Workflows::Coordinator.finish(facts, token: "long-call", outcome: Workflows::Outcome.succeeded("done"))

        assert_equal "ready", run.step(:author_facts_late).reload.state
      end

      # on_terminal fires only when a worker finishes or fails a step, never for a
      # skip_if skip (engine rule, Coordinator#settle_terminal).
      test "a skipped AI step does not hand books on (the skip never ran it)" do
        ::Services::Books::Authors::LedgerRun.stubs(:ai_step_ran_ids).returns(Set[@author.id])
        ::Books::Authors::EnrichJob.expects(:hand_off).never
        stub_services(wikidata: :matched)
        run = start(options: {skip_ai_if_ran: true})
        run_step(run, :wikidata)
      end
    end
  end
end
