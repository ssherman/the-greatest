# frozen_string_literal: true

require "test_helper"

class Books::Goodreads::SettleEditionsJobTest < ActiveSupport::TestCase
  include GoodreadsImportHelper

  SETTLE = Services::Books::GoodreadsImports::SettleEdition

  setup do
    stub_resolution_services
    # The resumed import would run inline and resolve again; these tests are
    # about the settle step. The resume has its own test below.
    Services::Books::GoodreadsImports::RunImport.stubs(:resume_waiting)
    @import = Books::GoodreadsImport.create!(user: users(:editor_user), status: :verifying)
  end

  def waiting_edition(**attributes)
    edition = goodreads_edition(goodreads_book_id: 90_000_001, **attributes)
    decision = MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition, outcome: :unmatched,
      confidence: :high, decided_by: :rule)
    edition.update!(verification: :pending, match_decision: decision, pending_import: @import)
    @import.rows.create!(row_number: @import.rows.count + 1, goodreads_edition: edition)
    edition
  end

  test "runs on the default queue" do
    assert_equal "default", Books::Goodreads::SettleEditionsJob.get_sidekiq_options["queue"].to_s
  end

  test "settles every waiting edition of the id against its page" do
    honest = waiting_edition
    hostile = waiting_edition(title: "A Book Nobody Wrote", signature: Books::Goodreads::ExportRow.signature("A Book Nobody Wrote", "Anna Brenner"))
    goodreads_page(goodreads_book_id: 90_000_001)

    Books::Goodreads::SettleEditionsJob.new.perform(90_000_001)

    assert_equal [true, true], [honest.reload.verification_verified?, honest.book.provisional?]
    assert_equal [true, true], [hostile.reload.parked?, hostile.verification_mismatch?]
  end

  test "an edition that fails records why on its waiting rows, and the rest still settle" do
    first = waiting_edition
    second = waiting_edition(title: "The Loud Year", signature: Books::Goodreads::ExportRow.signature("The Loud Year", "Anna Brenner"))
    SETTLE.expects(:call).twice.raises(RuntimeError, "boom").then.returns(nil)

    Books::Goodreads::SettleEditionsJob.new.perform(90_000_001)

    assert_equal ["verification failed: RuntimeError: boom", nil], [first.import_rows.sole.error, second.import_rows.sole.error]
  end

  test "an edition that failed and then settles on a later run leaves no error on its rows" do
    edition = waiting_edition
    SETTLE.stubs(:call).raises(RuntimeError, "boom")
    Books::Goodreads::SettleEditionsJob.new.perform(90_000_001)
    SETTLE.unstub(:call)

    Books::Goodreads::SettleEditionsJob.new.perform(90_000_001)

    assert_equal [true, nil], [edition.reload.created?, edition.import_rows.sole.error]
  end

  test "a book created unverified and then deleted is left for the finder, not created again" do
    book = Books::Book.create!(title: "The Quiet Year", provisional: true)
    edition = goodreads_edition(goodreads_book_id: 90_000_001, book: book, resolution: :created, verification: :unverified,
      resolved_at: 1.day.ago)
    @import.rows.create!(row_number: 1, goodreads_edition: edition)
    goodreads_page(goodreads_book_id: 90_000_001)
    book.destroy!

    assert_no_difference("Books::Book.count") { Books::Goodreads::SettleEditionsJob.new.perform(90_000_001) }

    assert_nil edition.reload.book_id
  end

  test "a Postgres error re-raises" do
    waiting_edition
    SETTLE.stubs(:call).raises(ActiveRecord::StatementInvalid, "connection lost")

    assert_raises(ActiveRecord::StatementInvalid) { Books::Goodreads::SettleEditionsJob.new.perform(90_000_001) }
  end

  test "resumes imports waiting on this Goodreads id" do
    ::Services::Books::GoodreadsImports::RunImport.expects(:resume_waiting).with(goodreads_book_id: 123)

    Books::Goodreads::SettleEditionsJob.new.perform(123)
  end
end
