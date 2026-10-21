# frozen_string_literal: true

require "test_helper"

class Books::Authors::EnrichJobTest < ActiveSupport::TestCase
  include Workflows::DispatchHelper

  def setup
    @author = ::Books::Author.create!(name: "Anna Brenner")
    @waiting = ::Books::Book.create!(title: "The Quiet Year")
    @waiting.book_authors.create!(author: @author, position: 1)
    ::Services::Books::DeferredEnrichment.defer!(@waiting)
    @never_waited = ::Books::Book.create!(title: "Never Waited")
    @never_waited.book_authors.create!(author: @author, position: 1)
  end

  def outcome(success)
    ::Services::Books::Authors::EnrichAuthor::Result.new(success?: success, data: {enrichments: []}, errors: success ? [] : ["timeout"])
  end

  def author_runs
    WorkflowRun.where(enrichable: @author, workflow: "books.author_enrichment")
  end

  test "runs on the author_chain queue with three retries" do
    options = Books::Authors::EnrichJob.get_sidekiq_options

    assert_equal ["author_chain", 3], [options["queue"].to_s, options["retry"]]
  end

  test "an in-flight message plans an author run with only the AI step, passing allow_research" do
    stub_workflow_dispatch
    ::Services::Books::Authors::EnrichAuthor.expects(:call).never

    Books::Authors::EnrichJob.new.perform(@author.id, false)

    run = author_runs.sole
    assert_equal [["author_facts"], false, "legacy_job"], [run.options["only"], run.options["allow_research"], run.initiated_by]
    assert_equal "ready", run.step(:author_facts).state
    assert_equal %w[not_requested], run.steps.where.not(key: "author_facts").distinct.pluck(:outcome)
  end

  test "an author with an active run plans nothing new and runs no AI of its own" do
    stub_workflow_dispatch
    active = Workflows::Books::AuthorEnrichment.start(@author, initiated_by: "test")
    ::Services::Books::Authors::EnrichAuthor.expects(:call).never
    ::Books::EnrichBookJob.expects(:perform_async).never

    Books::Authors::EnrichJob.new.perform(@author.id)

    assert_equal [active.id], author_runs.pluck(:id)
  end

  test "run inline, the planned AI step enriches the author once and hands on only the waiting books" do
    ::Services::Books::Authors::EnrichAuthor.expects(:call).with(author: @author, allow_research: true).once.returns(outcome(true))
    ::Books::EnrichBookJob.expects(:perform_async).with(@waiting.id).once
    ::Books::EnrichBookJob.expects(:perform_async).with(@never_waited.id).never

    Books::Authors::EnrichJob.new.perform(@author.id)

    assert_equal "completed", author_runs.sole.status
  end

  test "hand_off enqueues only the books whose latest row is the deferral" do
    ::Books::EnrichBookJob.expects(:perform_async).with(@waiting.id).once
    ::Books::EnrichBookJob.expects(:perform_async).with(@never_waited.id).never

    Books::Authors::EnrichJob.hand_off(@author.id)
  end

  test "hand_off skips a waiting book that has a running book run; its book_facts step enriches it" do
    owned = ::Books::Book.create!(title: "Adopted Book")
    owned.book_authors.create!(author: @author, position: 1)
    ::Services::Books::DeferredEnrichment.defer!(owned)
    stub_workflow_dispatch
    Workflows::Books::BookEnrichment.start(owned, initiated_by: "test", options: {only: ["book_facts"]})
    ::Books::EnrichBookJob.expects(:perform_async).with(owned.id).never
    ::Books::EnrichBookJob.expects(:perform_async).with(@waiting.id).once

    Books::Authors::EnrichJob.hand_off(@author.id)
  end

  test "hand_off does nothing for a deleted author" do
    ::Books::EnrichBookJob.expects(:perform_async).never

    Books::Authors::EnrichJob.hand_off(0)
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichAuthor.expects(:call).never
    ::Books::EnrichBookJob.expects(:perform_async).never

    assert_no_difference(-> { WorkflowRun.count }) { Books::Authors::EnrichJob.new.perform(0) }
  end
end
