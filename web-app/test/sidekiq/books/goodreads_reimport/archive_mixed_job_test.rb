require "test_helper"

class Books::GoodreadsReimport::ArchiveMixedJobTest < ActiveSupport::TestCase
  setup do
    @config = Rails.configuration.x.goodreads_reimport
    @was = @config.enabled
  end

  teardown { @config.enabled = @was }

  test "does nothing while the gate is off" do
    @config.enabled = false
    Services::Books::GoodreadsReimport::MixedBooks.expects(:archive).never

    Books::GoodreadsReimport::ArchiveMixedJob.new.perform([books_books(:war_and_peace).id])
  end

  test "archives each book with one shared legacy map and survives one raising" do
    @config.enabled = true
    first, second = [books_books(:war_and_peace), books_books(:of_mice_and_men)].sort_by(&:id)
    map = Object.new
    Services::Books::GoodreadsRebuild::LegacyBookMap.expects(:build).once.returns(map)
    Services::Books::GoodreadsReimport::MixedBooks.expects(:archive).with(first, legacy_map: map)
    Services::Books::GoodreadsReimport::MixedBooks.expects(:archive).with(second, legacy_map: map).raises(RuntimeError, "boom")
    Rails.logger.stubs(:error)
    Rails.logger.expects(:info).with { |line| line.include?("archived 1") && line.include?("errors 1") }

    Books::GoodreadsReimport::ArchiveMixedJob.new.perform([first.id, second.id])
  end

  test "enqueue queues the mixed books in slices of 100" do
    Services::Books::GoodreadsReimport::MixedBooks.stubs(:ids).returns(Set.new(1..150))
    batches = []
    Books::GoodreadsReimport::ArchiveMixedJob.stubs(:perform_async).with { |batch| batches << batch }

    assert_equal 150, Books::GoodreadsReimport::ArchiveMixedJob.enqueue
    assert_equal [100, 50], batches.map(&:size)
  end
end
