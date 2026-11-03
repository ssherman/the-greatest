require "test_helper"

class Books::GoodreadsReimport::DecideRowsJobTest < ActiveSupport::TestCase
  def result(outcome) = Services::Books::GoodreadsReimport::DecideRow::Result.new(success?: true, data: {outcome: outcome}, errors: [])

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
    Services::Books::GoodreadsReimport::DecideRow.expects(:call).never

    Books::GoodreadsReimport::DecideRowsJob.new.perform([row(@replay, 1).id])
  end

  test "decides each row and survives one raising" do
    @config.enabled = true
    a, b = row(@replay, 2), row(@replay, 3)
    Services::Books::GoodreadsReimport::DecideRow.expects(:call).with(row: a).returns(result(:recorded))
    Services::Books::GoodreadsReimport::DecideRow.expects(:call).with(row: b).raises(RuntimeError, "boom")
    Rails.logger.stubs(:error)
    Rails.logger.expects(:info).with("decide_rows batch: 2 rows — recorded 1, waiting 0, kept 0, errors 1")

    Books::GoodreadsReimport::DecideRowsJob.new.perform([a.id, b.id])
  end

  test "enqueue queues replayed rows that have an edition, in slices, and honours the limit" do
    edition = Books::GoodreadsEdition.create!(goodreads_book_id: 96_001, signature: "dj-sig", title: "T", primary_author: "A")
    ids = 3.times.map { |i| Books::GoodreadsImportRow.create!(import: @replay, row_number: 100 + i, raw: {}, goodreads_edition: edition).id }
    Books::GoodreadsImportRow.create!(import: @replay, row_number: 200, raw: {}) # no edition: nothing to decide against
    Books::GoodreadsImportRow.create!(import: books_goodreads_imports(:regular_user_import), row_number: 201, raw: {}, goodreads_edition: edition)
    batches = []
    Books::GoodreadsReimport::DecideRowsJob.stubs(:perform_async).with { |batch| batches << batch }

    assert_equal 3, Books::GoodreadsReimport::DecideRowsJob.enqueue
    assert_equal [ids], batches
    batches.clear
    assert_equal 2, Books::GoodreadsReimport::DecideRowsJob.enqueue(limit: 2)
    assert_equal [ids.first(2)], batches
  end
end
