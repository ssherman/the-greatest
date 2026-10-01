# frozen_string_literal: true

require "test_helper"

class Books::Authors::ViafJobTest < ActiveSupport::TestCase
  def setup
    @author = books_authors(:tolstoy)
    # Sidekiq runs inline in tests: a real enqueue would run the next step.
    Books::Authors::EnrichJob.stubs(:perform_async)
    Books::Authors::WikidataJob.stubs(:perform_async)
  end

  def outcome(wikidata_qid: nil, needs_review: false)
    decision = stub(needs_review: needs_review)
    ::Services::Books::Authors::EnrichFromViaf::Result.new(success?: true,
      data: {outcome: :matched, wikidata_qid: wikidata_qid, decision: decision}, errors: [])
  end

  def job_with_jitter(seconds)
    Books::Authors::ViafJob.new.tap { |job| job.stubs(:rand).returns(seconds) }
  end

  test "runs on the low queue with three retries" do
    options = Books::Authors::ViafJob.get_sidekiq_options

    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the VIAF step, passing refresh through, then the AI step" do
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).with(author: @author, refresh: true).returns(outcome)
    Books::Authors::WikidataJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id)

    Books::Authors::ViafJob.new.perform(@author.id, true)
  end

  test "a newly found Wikidata id sends the author back to Wikidata once, forced, and the AI step waits for that run" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243"))
    Books::Authors::WikidataJob.expects(:perform_async).with(@author.id, true, true)
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(@author.id)
  end

  test "a Wikidata id from a decision that needs review goes straight to the AI step" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243", needs_review: true))
    Books::Authors::WikidataJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id)

    Books::Authors::ViafJob.new.perform(@author.id)
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).never
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(0)
  end

  test "a VIAF pause queues the AI step at once and reschedules itself, remembering that it did" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id).once
    Books::Authors::ViafJob.expects(:perform_in).with(3607, @author.id, false, true)

    job_with_jitter(7).perform(@author.id)
  end

  test "a pause on a rescheduled run does not queue the AI step again" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(3607, @author.id, false, true)

    job_with_jitter(7).perform(@author.id, false, true)
  end

  test "a busy pace only reschedules, keeping refresh and what was already queued" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("VIAF pace busy", retry_after: 30))
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(37, @author.id, true, false)

    job_with_jitter(7).perform(@author.id, true)
  end

  test "a rescheduled run that finishes does not queue the AI step a second time" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome)
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(@author.id, false, true)
  end

  test "a rescheduled run that finds a Wikidata id still sends the author back to Wikidata" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243"))
    Books::Authors::WikidataJob.expects(:perform_async).with(@author.id, true, true)

    Books::Authors::ViafJob.new.perform(@author.id, false, true)
  end
end
