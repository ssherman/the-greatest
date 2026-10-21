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
