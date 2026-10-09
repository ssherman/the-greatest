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

  def catalog_report
    Services::BooksMigration::SyncPlan.build(now: Time.current, legacy: FakeLegacySource.new).report
  end

  def user_data
    {
      users: {legacy: 69_602, here: 69_590, inserted: 12, updated: 40, deleted_on_legacy: 2},
      user_lists: {legacy: 10, here: 9, inserted: 2, updated: 3, deleted: 1},
      user_list_items: {legacy: 100, here: 98, inserted: 5, deleted: 3, dropped: 1, waiting: 2, collisions: 1, missing: 0},
      reviews: {legacy: 20, here: 19, inserted: 1, updated: 2, deleted: 0, dropped: 0, waiting: 0, collisions: 1, held_by_new_app: 0, missing: 0},
      saved_searches: {legacy: 5, here: 5, inserted: 0, updated: 1, deleted: 0, categories_removed: 3},
      reading_goals: {legacy: 3, here: 3, deleted: 0},
      recommendation_configs: {legacy: 33, here: 33},
      corrections: {legacy: 800, here: 798, inserted: 2, dropped: 0, waiting: 0, missing: 2}
    }
  end

  test "renders the user-data half when given" do
    out = Services::BooksMigration::SyncReport.new(catalog_report, user_data).render

    assert_includes out, "User data"
    assert_match(/users\s+69,602\s+69,590\s+12\s+40\s+—/, out)
    assert_includes out, "2 deleted on legacy (counted, not applied)"
    assert_match(/user_list_items\s+100\s+98\s+5\s+—\s+3\s+1\s+2/, out)
    assert_includes out, "3 deleted categories removed from criteria"
    refute_includes out, "MISSING"
  end

  test "warns when list items or reviews would fail the sync" do
    data = user_data
    data[:reviews] = data[:reviews].merge(missing: 4)

    out = Services::BooksMigration::SyncReport.new(catalog_report, data).render

    assert_includes out, "MISSING: 4"
  end

  test "without user data it prints only the catalog" do
    refute_includes Services::BooksMigration::SyncReport.new(catalog_report).render, "User data"
  end
end
