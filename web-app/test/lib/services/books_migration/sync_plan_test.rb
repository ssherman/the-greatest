require "test_helper"

class Services::BooksMigration::SyncPlanTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  NOW = Time.zone.parse("2026-10-08 12:00:00")
  OLD = NOW - 2.days
  RECENT = NOW - 1.hour

  def plan(final: false, **legacy)
    Services::BooksMigration::SyncPlan.build(final: final, now: NOW, legacy: FakeLegacySource.new(**legacy))
  end

  test "scopes legacy books above the watermark that are more than a day old" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    result = plan(book_rows: [[100, OLD], [101, OLD], [102, OLD]])

    assert result.initialized?
    assert_equal Set[101, 102], result.scope.book_ids
    assert_equal 102, result.next_watermarks["books"]
  end

  test "waits on a book inside the delay and on every id after it" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    result = plan(book_rows: [[101, OLD], [102, RECENT], [103, OLD]])

    assert_equal Set[101], result.scope.book_ids
    assert_equal 101, result.next_watermarks["books"]
    assert_equal 2, result.report[:books][:waiting]
  end

  test "FINAL takes every row above the watermark" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    result = plan(final: true, book_rows: [[101, OLD], [102, RECENT], [103, OLD]])

    assert_equal Set[101, 102, 103], result.scope.book_ids
    assert_equal 0, result.report[:books][:waiting]
  end

  test "scopes authors and book identifiers the same way" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    result = plan(author_rows: [[51, OLD], [52, RECENT]], book_identifier_rows: [[500, OLD], [501, OLD], [502, RECENT]])

    assert_equal Set[51], result.scope.author_ids
    assert_equal Set[501], result.scope.identifier_ids
    assert_equal({"books" => 100, "authors" => 51, "book_identifiers" => 501}, result.next_watermarks)
  end

  test "leaves a redirected id out of the run but moves the watermark past it" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 101, to_id: nil)
    RecordRedirect.create!(item_type: "Books::Author", from_id: 51, to_id: 9)

    result = plan(book_rows: [[101, OLD], [102, OLD]], author_rows: [[51, OLD]])

    assert_equal Set[102], result.scope.book_ids
    assert_empty result.scope.author_ids
    assert_equal 102, result.next_watermarks["books"]
    assert_equal 51, result.next_watermarks["authors"]
    assert_equal 1, result.report[:books][:skipped_redirected]
  end

  test "keeps every watermark when legacy has nothing new" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    result = plan

    assert_equal({"books" => 100, "authors" => 50, "book_identifiers" => 500}, result.next_watermarks)
  end

  test "before sync_init it starts from the highest legacy-origin ids here and scopes no identifiers" do
    ::Books::Book.create!(id: 1_500, title: "Last Legacy Book")
    ::Books::Author.create!(id: 700, name: "Last Legacy Author")

    result = plan(book_rows: [[1_501, OLD]], book_identifier_rows: [[9, OLD]])

    refute result.initialized?
    assert_equal({"books" => 1_500, "authors" => 700, "book_identifiers" => nil}, result.watermarks)
    assert_equal Set[1_501], result.scope.book_ids
    assert_empty result.scope.identifier_ids
    assert_nil result.report[:book_identifiers][:would_insert]
    assert_nil result.report[:legacy_edits_not_synced]
  end

  test "raises naming the missing keys when the watermarks are incomplete" do
    LegacySyncWatermark.create!(key: "books", value: 100)

    error = assert_raises(RuntimeError) { plan }

    assert_includes error.message, "authors"
    assert_includes error.message, "book_identifiers"
  end

  test "would insert counts scoped books that are not already here" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    ::Books::Book.create!(id: 101, title: "Inserted By A Failed Run")

    result = plan(book_rows: [[101, OLD], [102, OLD]])

    assert_equal 1, result.report[:books][:would_insert]
  end

  test "reports legacy-origin rows here that legacy no longer has" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    ::Books::Book.create!(id: 90, title: "Deleted On Legacy")
    ::Books::Book.create!(id: 91, title: "Still On Legacy")
    ::Books::Author.create!(id: 40, name: "Deleted Author On Legacy")

    result = plan(book_ids: [91], author_ids: [])

    assert_equal [90], result.report[:books][:legacy_deleted_still_here]
    assert_equal [40], result.report[:authors][:legacy_deleted_still_here]
    assert_equal 2, result.report[:books][:here]
    assert_equal 1, result.report[:books][:legacy]
  end

  test "counts legacy categories with no map entry" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    LegacyIdMap.record(model: "Books::Category", legacy_id: 7, new_id: 1)

    assert_equal 1, plan(category_ids: [7, 8]).report[:categories_unmapped]
  end

  test "reports legacy edits to existing books once initialized" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    assert_equal 4, plan(books_updated_count: 4).report[:legacy_edits_not_synced]
  end

  test "reports the recorded redirects" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 5, to_id: 9)

    assert_equal({merged: 1, deleted: 0}, plan.report[:redirects]["Books::Book"])
  end

  test "the scope carries the books watermark the run advances to" do
    init_watermarks(books: 1_000, authors: 500, book_identifiers: 5_000)
    legacy = FakeLegacySource.new(book_rows: [[1_001, 3.days.ago], [1_002, 1.hour.ago]])

    assert_equal 1_001, Services::BooksMigration::SyncPlan.build(legacy: legacy).scope.books_watermark
  end

  test "with no new books the scope's books watermark stays where it was" do
    init_watermarks(books: 1_000, authors: 500, book_identifiers: 5_000)

    assert_equal 1_000, Services::BooksMigration::SyncPlan.build(legacy: FakeLegacySource.new).scope.books_watermark
  end
end
