# frozen_string_literal: true

require "test_helper"

class Books::Goodreads::VerifyUnverifiedJobTest < ActiveSupport::TestCase
  include GoodreadsImportHelper

  # FetchPageJob is not stubbed here: each test names exactly the fetches it
  # expects, so a stray one (a non-provisional book, an edition waiting only
  # minutes) fails as an unexpected invocation.
  setup do
    Books::Goodreads::SettleEditionsJob.stubs(:perform_async)
  end

  def created_unverified(goodreads_book_id, provisional: true)
    book = Books::Book.create!(title: "Book #{goodreads_book_id}", provisional: provisional)
    goodreads_edition(goodreads_book_id: goodreads_book_id, book: book, resolution: :created, verification: :unverified,
      resolved_at: 1.day.ago)
  end

  test "runs on the low queue" do
    assert_equal "low", Books::Goodreads::VerifyUnverifiedJob.get_sidekiq_options["queue"].to_s
  end

  test "queues a fetch for each provisional book created unverified, and for editions stuck waiting" do
    created_unverified(91_000_001)
    created_unverified(91_000_002, provisional: false)
    goodreads_edition(goodreads_book_id: 91_000_003, verification: :pending).update_column(:updated_at, 8.hours.ago)
    goodreads_edition(goodreads_book_id: 91_000_004, verification: :pending)
    # A full day's line is 1,500 turns 15 s apart (6.25 h): two hours of
    # waiting is a turn not yet come, not a lost job.
    goodreads_edition(goodreads_book_id: 91_000_005, verification: :pending).update_column(:updated_at, 2.hours.ago)
    Books::Goodreads::FetchPageJob.expects(:perform_async).with(91_000_001)
    Books::Goodreads::FetchPageJob.expects(:perform_async).with(91_000_003)

    Books::Goodreads::VerifyUnverifiedJob.new.perform
  end

  test "an id whose page is already cached is settled without a fetch" do
    created_unverified(91_000_001)
    goodreads_page(goodreads_book_id: 91_000_001)
    Books::Goodreads::FetchPageJob.expects(:perform_async).never
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(91_000_001)

    Books::Goodreads::VerifyUnverifiedJob.new.perform
  end

  test "takes at most limit ids" do
    created_unverified(91_000_001)
    created_unverified(91_000_002)
    Books::Goodreads::FetchPageJob.expects(:perform_async).once

    Books::Goodreads::VerifyUnverifiedJob.new.perform(1)
  end
end
