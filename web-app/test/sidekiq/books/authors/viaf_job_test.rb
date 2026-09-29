# frozen_string_literal: true

require "test_helper"

class Books::Authors::ViafJobTest < ActiveSupport::TestCase
  def outcome(wikidata_qid: nil, needs_review: false)
    decision = stub(needs_review: needs_review)
    ::Services::Books::Authors::EnrichFromViaf::Result.new(success?: true,
      data: {outcome: :matched, wikidata_qid: wikidata_qid, decision: decision}, errors: [])
  end

  test "runs on the low queue with three retries" do
    options = Books::Authors::ViafJob.get_sidekiq_options

    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the VIAF step for the author, passing refresh through" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).with(author: author, refresh: true).returns(outcome)
    Books::Authors::WikidataJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(author.id, true)
  end

  test "a newly found Wikidata id sends the author back to Wikidata once, forced, and never back here" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243"))
    Books::Authors::WikidataJob.expects(:perform_async).with(author.id, true, true)

    Books::Authors::ViafJob.new.perform(author.id)
  end

  test "a newly found Wikidata id from a decision that needs review does not send the author back" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243", needs_review: true))
    Books::Authors::WikidataJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(author.id)
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).never

    Books::Authors::ViafJob.new.perform(0)
  end

  test "reschedules itself after the wait a pause or busy pace carries, plus jitter" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("paused", retry_after: 3600))
    job = Books::Authors::ViafJob.new
    job.stubs(:rand).returns(7)
    Books::Authors::ViafJob.expects(:perform_in).with(3607, author.id, false)

    job.perform(author.id)
  end
end
