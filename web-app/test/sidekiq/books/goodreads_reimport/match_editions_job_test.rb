require "test_helper"

class Books::GoodreadsReimport::MatchEditionsJobTest < ActiveSupport::TestCase
  def result(outcome) = Services::Books::GoodreadsReimport::MatchEdition::Result.new(success?: true, data: {outcome: outcome}, errors: [])

  def edition(number)
    Books::GoodreadsEdition.create!(goodreads_book_id: 70_000 + number, signature: "job-sig-#{number}", title: "T#{number}", primary_author: "A")
  end

  def rows(edition, count, import:)
    count.times do
      Books::GoodreadsImportRow.create!(import: import, row_number: (@row_number += 1), raw: {"Title" => "T"}, goodreads_edition: edition)
    end
  end

  setup do
    @row_number = 8_000
    @replay = Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete)
    @config = Rails.configuration.x.goodreads_reimport
    @was = @config.enabled
  end

  teardown { @config.enabled = @was }

  test "does nothing while the gate is off" do
    @config.enabled = false
    Services::Books::GoodreadsReimport::MatchEdition.expects(:call).never

    Books::GoodreadsReimport::MatchEditionsJob.new.perform([edition(1).id])
  end

  test "matches each edition with the mixed book ids computed once, and survives one raising" do
    @config.enabled = true
    a, b = edition(2), edition(3)
    mixed = Set[42]
    Services::Books::GoodreadsReimport::MixedBooks.expects(:ids).once.returns(mixed)
    Services::Books::GoodreadsReimport::MatchEdition.expects(:call).with(edition: a, exclude_ids: mixed).returns(result(:matched))
    Services::Books::GoodreadsReimport::MatchEdition.expects(:call).with(edition: b, exclude_ids: mixed).raises(RuntimeError, "boom")
    Rails.logger.stubs(:error)
    Rails.logger.expects(:info).with("match_editions batch: 2 editions — matched 1, create 0, kept 0, retry 0, errors 1")

    Books::GoodreadsReimport::MatchEditionsJob.new.perform([a.id, b.id])
  end

  test "enqueue queues replayed editions, most rows first, in slices of 100" do
    few, many = edition(4), edition(5)
    rows(few, 1, import: @replay)
    rows(many, 3, import: @replay)
    rows(edition(6), 5, import: books_goodreads_imports(:regular_user_import)) # a member import is out of scope
    batches = []
    Books::GoodreadsReimport::MatchEditionsJob.stubs(:perform_async).with { |ids| batches << ids }

    assert_equal 2, Books::GoodreadsReimport::MatchEditionsJob.enqueue(limit: nil)
    assert_equal [[many.id, few.id]], batches
  end

  test "enqueue honours the limit" do
    a, b = edition(7), edition(8)
    rows(a, 2, import: @replay)
    rows(b, 1, import: @replay)
    Books::GoodreadsReimport::MatchEditionsJob.expects(:perform_async).with([a.id])

    assert_equal 1, Books::GoodreadsReimport::MatchEditionsJob.enqueue(limit: 1)
  end
end
