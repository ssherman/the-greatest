# frozen_string_literal: true

require "test_helper"

class Books::Authors::WikidataJobTest < ActiveSupport::TestCase
  def setup
    @author = books_authors(:king)
    # Sidekiq runs inline in tests: planning a run would execute its steps.
    stub_workflow_dispatch
  end

  def planned = WorkflowRun.find_by!(enrichable: @author, workflow: "books.author_enrichment")

  test "runs on the author_chain queue with three retries" do
    options = Books::Authors::WikidataJob.get_sidekiq_options

    assert_equal ["author_chain", 3], [options["queue"].to_s, options["retry"]]
  end

  test "an in-flight message plans an author run instead of chaining" do
    Books::Authors::ViafJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::WikidataJob.new.perform(@author.id, false, false, false)

    assert_equal [false, "legacy_job"], [planned.options["allow_research"], planned.initiated_by]
  end

  test "refresh carries into the run, and so does via_viaf, which was a forced hop" do
    Books::Authors::WikidataJob.new.perform(@author.id, true)
    assert_equal [true, true], planned.options.values_at("refresh", "allow_research")
    planned.update!(status: :cancelled)

    Books::Authors::WikidataJob.new.perform(@author.id, false, true)
    assert_equal true, WorkflowRun.running.find_by!(enrichable: @author).options["refresh"]
  end

  test "an author with an active run gets no second one" do
    Workflows::Books::AuthorEnrichment.start(@author, initiated_by: "test")

    assert_no_difference -> { WorkflowRun.count } do
      Books::Authors::WikidataJob.new.perform(@author.id)
    end
  end

  test "does nothing for an author deleted since enqueue" do
    assert_no_difference -> { WorkflowRun.count } do
      Books::Authors::WikidataJob.new.perform(0)
    end
  end
end
