require "test_helper"

class Services::BooksMigration::SyncReportTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def render(**legacy)
    plan = Services::BooksMigration::SyncPlan.build(now: Time.current, legacy: FakeLegacySource.new(**legacy))
    Services::BooksMigration::SyncReport.render(plan)
  end

  test "shows the catalog numbers, redirects and legacy edits" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 5, to_id: 9)

    out = render(book_rows: [[101, 3.days.ago], [102, 1.hour.ago]], book_identifier_rows: [[501, 3.days.ago]], books_updated_count: 87)

    assert_match(/books \(above watermark\)\s+2\s+0\s+1\s+1/, out)
    assert_includes out, "book_identifiers (new legacy rows; deduped on insert)"
    assert_includes out, "redirects recorded: books merged 1, deleted 0; authors merged 0, deleted 0"
    assert_includes out, "legacy edits to existing books, not synced: 87"
  end

  test "before sync_init it says so" do
    out = render

    assert_includes out, "Before sync_init"
    assert_includes out, "n/a before sync_init"
  end

  test "lists at most twenty legacy-deleted ids" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    22.times { |i| ::Books::Book.create!(id: 10 + i, title: "Gone #{i}") }

    out = render(book_ids: [])

    assert_includes out, "books 22 (ids: 10, 11"
    assert_includes out, "and 2 more"
  end
end
