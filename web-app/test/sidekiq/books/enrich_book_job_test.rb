require "test_helper"

class Books::EnrichBookJobTest < ActiveSupport::TestCase
  def setup
    @book = books_books(:war_and_peace)
    @job = Books::EnrichBookJob.new
  end

  test "runs on the low queue with three retries" do
    assert_equal "low", Books::EnrichBookJob.get_sidekiq_options["queue"].to_s
    assert_equal 3, Books::EnrichBookJob.get_sidekiq_options["retry"]
  end

  test "calls the runner with the book and defaults" do
    Services::Books::EnrichBook.expects(:call)
      .with(book: @book, force_research: false, author_names: [])
      .returns(Services::Books::EnrichBook::Result.new(success?: true, data: {enrichments: []}, errors: []))

    @job.perform(@book.id)
  end

  test "passes force_research and author names through" do
    Services::Books::EnrichBook.expects(:call)
      .with(book: @book, force_research: true, author_names: ["Leo Tolstoy"])
      .returns(Services::Books::EnrichBook::Result.new(success?: true, data: {enrichments: []}, errors: []))

    @job.perform(@book.id, true, ["Leo Tolstoy"])
  end

  test "re-raises on a failed result so Sidekiq retries" do
    Services::Books::EnrichBook.stubs(:call)
      .returns(Services::Books::EnrichBook::Result.new(success?: false, data: {enrichments: []}, errors: ["OpenAI timeout"]))

    error = assert_raises(StandardError) { @job.perform(@book.id) }
    assert_includes error.message, "OpenAI timeout"
    assert_includes error.message, @book.id.to_s
  end

  test "returns quietly when the book no longer exists" do
    Services::Books::EnrichBook.expects(:call).never

    assert_nothing_raised { @job.perform(-1) }
  end
end
