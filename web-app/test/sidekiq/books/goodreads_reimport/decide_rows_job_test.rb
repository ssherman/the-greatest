require "test_helper"

class Books::GoodreadsReimport::DecideRowsJobTest < ActiveSupport::TestCase
  def result(tally) = Services::Books::GoodreadsReimport::DecideRow::Result.new(success?: true, data: {tally: tally}, errors: [])

  def row(import, number)
    Books::GoodreadsImportRow.create!(import: import, row_number: number, raw: {"Title" => "T"})
  end

  setup do
    @replay = Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete)
    @config = Rails.configuration.x.goodreads_reimport
    @was = @config.enabled
  end

  teardown { @config.enabled = @was }

  test "does nothing while the gate is off" do
    @config.enabled = false
    Services::Books::GoodreadsReimport::DecideRow.expects(:decide_user).never

    Books::GoodreadsReimport::DecideRowsJob.new.perform([@replay.user_id])
  end

  test "decides each user and survives one raising" do
    @config.enabled = true
    Services::Books::GoodreadsReimport::DecideRow.expects(:decide_user).with(user_id: 1).returns(result(recorded: 2, waiting: 1))
    Services::Books::GoodreadsReimport::DecideRow.expects(:decide_user).with(user_id: 2).raises(RuntimeError, "boom")
    Rails.logger.stubs(:error)
    Rails.logger.expects(:info).with("decide_rows batch: 2 users — recorded 2, waiting 1, kept 0, conflict 0, errors 1")

    Books::GoodreadsReimport::DecideRowsJob.new.perform([1, 2])
  end

  test "enqueue queues users who still have an undecided-or-unapplied row, in slices of 20, and honours the limit" do
    edition = Books::GoodreadsEdition.create!(goodreads_book_id: 96_001, signature: "dj-sig", title: "T", primary_author: "A")
    done_user = users(:admin_user)
    done_import = Books::GoodreadsImport.create!(user: done_user, source: :legacy_replay, status: :complete)
    done_row = Books::GoodreadsImportRow.create!(import: done_import, row_number: 1, raw: {}, goodreads_edition: edition)
    Books::RepairVerdict.create!(kind: :reimport_row, subject_key: "reimport:row:#{done_import.id}:1", decided_by: :rule,
      status: :approved, payload: {}, applied_at: Time.current)
    3.times { |i| Books::GoodreadsImportRow.create!(import: @replay, row_number: 100 + i, raw: {}, goodreads_edition: edition) }
    Books::GoodreadsImportRow.create!(import: @replay, row_number: 200, raw: {}) # no edition: nothing to decide against
    Books::GoodreadsImportRow.create!(import: books_goodreads_imports(:regular_user_import), row_number: 201, raw: {}, goodreads_edition: edition)
    batches = []
    Books::GoodreadsReimport::DecideRowsJob.stubs(:perform_async).with { |batch| batches << batch }

    assert_equal 1, Books::GoodreadsReimport::DecideRowsJob.enqueue
    assert_equal [[@replay.user_id]], batches
    assert_equal 0, Books::GoodreadsReimport::DecideRowsJob.enqueue(limit: 0)
    assert done_row
  end
end
