require "test_helper"

class Services::BooksMigration::EditionIsbnIdentifierMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::EditionIsbnIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "migrates edition jsonb isbn/ean arrays as work-level identifiers on the book" do
    book = Books::Book.create!(title: "Ed ISBN Book")
    result = run_migrator([{"id" => 100, "book_id" => book.id,
                            "identifiers" => {"isbn_10" => ["0375755349"], "isbn_13" => ["9780375755347"], "ean" => ["9780375755347"], "asin" => ""}}])
    assert result[:success], result[:error]
    types = Identifier.where(identifiable: book).pluck(:identifier_type).sort
    assert_equal ["books_work_ean13", "books_work_isbn10", "books_work_isbn13"], types
  end

  test "fans out a multi-valued array into one identifier per value" do
    book = Books::Book.create!(title: "Multi EAN Book")
    run_migrator([{"id" => 101, "book_id" => book.id,
                   "identifiers" => {"ean" => ["9780375755347", "9781234567897"]}}])
    assert_equal 2, Identifier.where(identifiable: book, identifier_type: :books_work_ean13).count
  end

  test "reclassifies an ISBN-10-shaped asin and keeps a Kindle asin" do
    b1 = Books::Book.create!(title: "Phys Ed")
    b2 = Books::Book.create!(title: "Kindle Ed")
    run_migrator([
      {"id" => 102, "book_id" => b1.id, "identifiers" => {"asin" => "0375755349"}},
      {"id" => 103, "book_id" => b2.id, "identifiers" => {"asin" => "B09LVX2Y9V"}}
    ])
    assert_equal "books_work_isbn10", Identifier.find_by(identifiable: b1).identifier_type
    assert_equal "books_work_asin", Identifier.find_by(identifiable: b2).identifier_type
  end

  test "handles empty, nil, and non-hash identifiers without error" do
    book = Books::Book.create!(title: "Empty Ed Book")
    assert_no_difference -> { Identifier.count } do
      result = run_migrator([
        {"id" => 104, "book_id" => book.id, "identifiers" => {}},
        {"id" => 105, "book_id" => book.id, "identifiers" => nil},
        {"id" => 106, "book_id" => book.id, "identifiers" => {"isbn_10" => [], "asin" => ""}}
      ])
      assert result[:success], result[:error]
    end
  end

  test "dedupes against an identifier already created by another source" do
    book = Books::Book.create!(title: "Dedup Ed Book")
    Identifier.create!(identifiable: book, identifier_type: :books_work_isbn13, value: "9780375755347")
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => 107, "book_id" => book.id, "identifiers" => {"isbn_13" => ["9780375755347"]}}])
    end
  end

  test "is idempotent on rerun" do
    book = Books::Book.create!(title: "Idem Ed Book")
    rows = [{"id" => 108, "book_id" => book.id, "identifiers" => {"isbn_10" => ["0375755349"]}}]
    run_migrator(rows)
    assert_no_difference -> { Identifier.count } do
      run_migrator(rows)
    end
  end

  test "suppresses search indexing during the load" do
    book = Books::Book.create!(title: "Quiet Ed Book")
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 109, "book_id" => book.id, "identifiers" => {"isbn_10" => ["0375755349"]}}])
    end
  end

  test "fails loud when book_id has no migrated Books::Book" do
    result = run_migrator([{"id" => 110, "book_id" => 999_999, "identifiers" => {"isbn_10" => ["0375755349"]}}])
    refute result[:success]
    assert_match(/legacy id=110/, result[:error])
  end
end
