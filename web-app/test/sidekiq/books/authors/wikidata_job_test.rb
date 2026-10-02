# frozen_string_literal: true

require "test_helper"

class Books::Authors::WikidataJobTest < ActiveSupport::TestCase
  def setup
    @author = books_authors(:tolstoy)
    # Sidekiq runs inline in tests: a real enqueue would run the next step.
    Books::Authors::EnrichJob.stubs(:perform_async)
    Books::Authors::ViafJob.stubs(:perform_async)
  end

  def outcome(value)
    ::Services::Books::Authors::EnrichFromWikidata::Result.new(success?: value != :failed, data: {outcome: value}, errors: [])
  end

  test "runs on the low queue with three retries" do
    options = Books::Authors::WikidataJob.get_sidekiq_options

    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the Wikidata step for the author" do
    ::Services::Books::Authors::EnrichFromWikidata.expects(:call).with(author: @author, refresh: true).returns(outcome(:matched))

    Books::Authors::WikidataJob.new.perform(@author.id, true)
  end

  test "a miss goes on to VIAF, passing refresh through, and not yet to the AI step" do
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(:unmatched))
    Books::Authors::ViafJob.expects(:perform_async).with(@author.id, true)
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::WikidataJob.new.perform(@author.id, true)
  end

  test "a match, a failure or a skip goes on to the AI step, not VIAF" do
    Books::Authors::ViafJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id).times(3)

    %i[matched failed skipped].each do |value|
      ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(value))
      Books::Authors::WikidataJob.new.perform(@author.id)
    end
  end

  test "a miss on a run VIAF sent here goes to the AI step, never back to VIAF" do
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(:unmatched))
    Books::Authors::ViafJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id)

    Books::Authors::WikidataJob.new.perform(@author.id, true, true)
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichFromWikidata.expects(:call).never
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::WikidataJob.new.perform(0)
  end

  test "reschedules itself after the wait a rate limit carries, plus jitter, keeping via_viaf" do
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 120))
    job = Books::Authors::WikidataJob.new
    job.stubs(:rand).returns(7)
    Books::Authors::WikidataJob.expects(:perform_in).with(127, @author.id, true, true)
    Books::Authors::EnrichJob.expects(:perform_async).never

    job.perform(@author.id, true, true)
  end
end
