# frozen_string_literal: true

require "test_helper"

class Books::Authors::EnrichJobTest < ActiveSupport::TestCase
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

  test "runs on the low queue with three retries" do
    options = Books::Authors::EnrichJob.get_sidekiq_options

    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the AI step, then hands on only the books that were waiting" do
    ::Services::Books::Authors::EnrichAuthor.expects(:call).with(author: @author, allow_research: true).returns(outcome(true))
    ::Books::EnrichBookJob.expects(:perform_async).with(@waiting.id).once
    ::Books::EnrichBookJob.expects(:perform_async).with(@never_waited.id).never

    Books::Authors::EnrichJob.new.perform(@author.id)
  end

  test "passes allow_research through" do
    ::Services::Books::Authors::EnrichAuthor.expects(:call).with(author: @author, allow_research: false).returns(outcome(true))
    ::Books::EnrichBookJob.stubs(:perform_async)

    Books::Authors::EnrichJob.new.perform(@author.id, false)
  end

  test "a failed run raises so Sidekiq retries it, and hands nothing on yet" do
    ::Services::Books::Authors::EnrichAuthor.stubs(:call).returns(outcome(false))
    ::Books::EnrichBookJob.expects(:perform_async).never

    error = assert_raises(StandardError) { Books::Authors::EnrichJob.new.perform(@author.id) }

    assert_includes error.message, "timeout"
  end

  test "when the retries run out, the waiting books are handed on anyway" do
    ::Books::EnrichBookJob.expects(:perform_async).with(@waiting.id).once

    Books::Authors::EnrichJob.sidekiq_retries_exhausted_block.call({"args" => [@author.id, true]}, StandardError.new("timeout"))
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichAuthor.expects(:call).never
    ::Books::EnrichBookJob.expects(:perform_async).never

    Books::Authors::EnrichJob.new.perform(0)
  end
end
