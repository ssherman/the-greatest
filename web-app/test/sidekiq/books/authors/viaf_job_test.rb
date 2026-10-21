# frozen_string_literal: true

require "test_helper"

class Books::Authors::ViafJobTest < ActiveSupport::TestCase
  def setup
    @author = books_authors(:king)
    # Sidekiq runs inline in tests: planning a run would execute its steps.
    stub_workflow_dispatch
  end

  test "runs on the author_chain queue with three retries" do
    options = Books::Authors::ViafJob.get_sidekiq_options

    assert_equal ["author_chain", 3], [options["queue"].to_s, options["retry"]]
  end

  test "an in-flight message plans a run starting at VIAF, skipping the AI step if it was queued" do
    Books::Authors::WikidataJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(@author.id, false, true, true, true)

    run = WorkflowRun.find_by!(enrichable: @author)
    assert_equal ["viaf", true, "legacy_job"], run.options.values_at("start_at", "skip_ai_if_ran") + [run.initiated_by]
  end

  test "an old message's in_line flag keeps its place in the line: the step asks VIAF instead of taking a new turn" do
    freeze_time
    schedule = ::Viaf::Schedule.new(redis: ::Books::OpenLibrary::FakeRedis.new)
    ::Viaf::Schedule.stubs(:new).returns(schedule)
    schedule.reserve(not_before: 30) # someone else is waiting in the line
    outcome = ::Services::Books::Authors::EnrichFromViaf::Result.new(success?: true,
      data: {outcome: :matched, wikidata_qid: nil, decision: nil}, errors: [])
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).once.returns(outcome)

    Books::Authors::ViafJob.new.perform(@author.id, false, false, true, true)

    run = WorkflowRun.find_by!(enrichable: @author)
    result = Workflows::Books::Steps::Viaf.new.call(step: run.step(:viaf), run: run, target: @author)
    assert_equal [true, :succeeded], [run.options["in_line"], result.kind]
  end

  test "a message that was not in the line joins it when someone is waiting" do
    freeze_time
    schedule = ::Viaf::Schedule.new(redis: ::Books::OpenLibrary::FakeRedis.new)
    ::Viaf::Schedule.stubs(:new).returns(schedule)
    schedule.reserve(not_before: 30)
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).never

    Books::Authors::ViafJob.new.perform(@author.id, false, false, true, false)

    run = WorkflowRun.find_by!(enrichable: @author)
    result = Workflows::Books::Steps::Viaf.new.call(step: run.step(:viaf), run: run, target: @author)
    assert_equal :wait, result.kind
  end

  test "refresh and research carry into the run, and an AI step not yet queued is not skipped" do
    Books::Authors::ViafJob.new.perform(@author.id, true, false, false)

    run = WorkflowRun.find_by!(enrichable: @author)
    assert_equal [true, false, false], run.options.values_at("refresh", "allow_research", "skip_ai_if_ran")
  end

  test "an author with an active run gets no second one" do
    Workflows::Books::AuthorEnrichment.start(@author, initiated_by: "test")

    assert_no_difference -> { WorkflowRun.count } do
      Books::Authors::ViafJob.new.perform(@author.id)
    end
  end

  test "does nothing for an author deleted since enqueue" do
    assert_no_difference -> { WorkflowRun.count } do
      Books::Authors::ViafJob.new.perform(0)
    end
  end
end
