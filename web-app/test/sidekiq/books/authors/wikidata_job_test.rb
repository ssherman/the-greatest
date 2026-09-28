# frozen_string_literal: true

require "test_helper"

class Books::Authors::WikidataJobTest < ActiveSupport::TestCase
  test "runs on the low queue with three retries" do
    options = Books::Authors::WikidataJob.get_sidekiq_options

    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the Wikidata step for the author" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromWikidata.expects(:call).with(author: author, refresh: true)

    Books::Authors::WikidataJob.new.perform(author.id, true)
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichFromWikidata.expects(:call).never

    Books::Authors::WikidataJob.new.perform(0)
  end

  test "reschedules itself after the wait a rate limit carries, plus jitter" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 120))
    job = Books::Authors::WikidataJob.new
    job.stubs(:rand).returns(7)
    Books::Authors::WikidataJob.expects(:perform_in).with(127, author.id, false)

    job.perform(author.id)
  end
end
