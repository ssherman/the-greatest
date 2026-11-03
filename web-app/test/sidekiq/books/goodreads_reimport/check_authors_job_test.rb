require "test_helper"

class Books::GoodreadsReimport::CheckAuthorsJobTest < ActiveSupport::TestCase
  setup do
    @config = Rails.configuration.x.goodreads_reimport
    @was = @config.enabled
  end

  teardown { @config.enabled = @was }

  test "does nothing while the gate is off" do
    @config.enabled = false
    Services::Books::GoodreadsReimport::CheckAuthor.expects(:call).never

    Books::GoodreadsReimport::CheckAuthorsJob.new.perform([books_books(:war_and_peace).id])
  end

  test "checks each book and survives one raising" do
    @config.enabled = true
    first, second = books_books(:war_and_peace), books_books(:of_mice_and_men)
    result = Services::Books::GoodreadsReimport::CheckAuthor::Result.new(success?: true, data: {outcome: :recorded}, errors: [])
    Services::Books::GoodreadsReimport::CheckAuthor.expects(:call).with(book: first).returns(result)
    Services::Books::GoodreadsReimport::CheckAuthor.expects(:call).with(book: second).raises(RuntimeError, "boom")
    Rails.logger.stubs(:error)
    Rails.logger.expects(:info).with("check_authors batch: 2 books — agrees 0, recorded 1, kept 0, failed 0, errors 1")

    Books::GoodreadsReimport::CheckAuthorsJob.new.perform([first.id, second.id])
  end

  test "enqueue queues the destinations of applied row verdicts in slices of 100 and honours the limit" do
    book = books_books(:war_and_peace)
    other = books_books(:of_mice_and_men)
    [[book.id, true], [book.id, true], [other.id, false]].each_with_index do |(to, applied), i|
      Books::RepairVerdict.create!(kind: :reimport_row, subject_key: "reimport:row:cj:#{i}", decided_by: :rule, status: :approved,
        applied_at: (Time.current if applied), payload: {"to_book_id" => to})
    end
    batches = []
    Books::GoodreadsReimport::CheckAuthorsJob.stubs(:perform_async).with { |batch| batches << batch }

    assert_equal 1, Books::GoodreadsReimport::CheckAuthorsJob.enqueue
    assert_equal [[book.id]], batches
    assert_equal 0, Books::GoodreadsReimport::CheckAuthorsJob.enqueue(limit: 0)
  end
end
