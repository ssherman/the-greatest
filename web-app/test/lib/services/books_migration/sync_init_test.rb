require "test_helper"

class Services::BooksMigration::SyncInitTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  test "records the highest legacy-origin book and author ids and legacy's max book_identifiers id" do
    ::Books::Book.create!(id: 1_500, title: "Last Legacy Book")
    ::Books::Author.create!(id: 700, name: "Last Legacy Author")

    result = Services::BooksMigration::SyncInit.call(legacy: FakeLegacySource.new(max_book_identifier_id: 88_000))

    assert result.success?, result.errors.inspect
    expected = {"books" => 1_500, "authors" => 700, "book_identifiers" => 88_000}
    assert_equal expected, result.data.slice(*LegacySyncWatermark::KEYS)
    assert_equal expected, LegacySyncWatermark.pluck(:key, :value).to_h
  end

  test "takes the book_identifiers watermark from an override recorded before the final :all" do
    result = Services::BooksMigration::SyncInit.call(legacy: FakeLegacySource.new(max_book_identifier_id: 88_000), book_identifiers: 80_000)

    assert result.success?, result.errors.inspect
    assert_equal 80_000, LegacySyncWatermark.find_by!(key: "book_identifiers").value
  end

  # The weekly :all ignores redirects, so a record deleted or merged away here before
  # sync_init comes back; its row would then drop or misroute its new legacy rows.
  test "removes redirect rows for records that exist here again" do
    ::Books::Book.create!(id: 1_500, title: "Restored By All")
    RecordRedirect.create!(item_type: "Books::Book", from_id: 1_500, to_id: nil)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 1_600, to_id: nil)
    ::Books::Author.create!(id: 700, name: "Restored Author")
    RecordRedirect.create!(item_type: "Books::Author", from_id: 700, to_id: 9)

    result = Services::BooksMigration::SyncInit.call(legacy: FakeLegacySource.new)

    assert_equal 2, result.data["stale_redirects_removed"]
    assert_equal [["Books::Book", 1_600]], RecordRedirect.pluck(:item_type, :from_id)
  end

  test "ignores new-app rows above the ceiling" do
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books")
    ::Books::Book.create!(id: 1_500, title: "Last Legacy Book")
    ::Books::Book.create!(id: ceiling + 1, title: "Goodreads Import")

    result = Services::BooksMigration::SyncInit.call(legacy: FakeLegacySource.new)

    assert_equal 1_500, result.data["books"]
  end

  test "refuses when watermarks already exist" do
    init_watermarks(books: 1, authors: 2, book_identifiers: 3)

    result = Services::BooksMigration::SyncInit.call(legacy: FakeLegacySource.new(max_book_identifier_id: 99))

    refute result.success?
    assert_match(/already exist/, result.errors.first)
    assert_equal 3, LegacySyncWatermark.find_by!(key: "book_identifiers").value
  end
end
