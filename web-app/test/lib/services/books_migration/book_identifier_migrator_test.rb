require "test_helper"

class Services::BooksMigration::BookIdentifierMigratorTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def run_migrator(rows)
    m = Services::BooksMigration::BookIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "migrates goodreads (type 5) as a work-level goodreads id on the book" do
    book = ::Books::Book.create!(title: "GR Book")
    result = run_migrator([{"id" => 1, "book_id" => book.id, "identifier_type" => 5, "identifier" => "1079398"}])
    assert result[:success], result[:error]
    idf = Identifier.find_by(identifiable: book)
    assert_equal "books_work_goodreads_id", idf.identifier_type
    assert_equal "1079398", idf.value
  end

  test "migrates isbn10 (type 1), isbn13 (type 2), ean13 (type 4) as work-level ids" do
    book = ::Books::Book.create!(title: "ISBN Book")
    result = run_migrator([
      {"id" => 2, "book_id" => book.id, "identifier_type" => 1, "identifier" => "0375755349"},
      {"id" => 3, "book_id" => book.id, "identifier_type" => 2, "identifier" => "9780375755347"},
      {"id" => 4, "book_id" => book.id, "identifier_type" => 4, "identifier" => "9780375755347"}
    ])
    assert result[:success], result[:error]
    types = Identifier.where(identifiable: book).pluck(:identifier_type).sort
    assert_equal ["books_work_ean13", "books_work_isbn10", "books_work_isbn13"], types
  end

  test "reclassifies an ISBN-10-shaped asin (type 3) as isbn10 but keeps a Kindle asin" do
    book = ::Books::Book.create!(title: "ASIN Book")
    run_migrator([
      {"id" => 7, "book_id" => book.id, "identifier_type" => 3, "identifier" => "0375755349"},
      {"id" => 8, "book_id" => book.id, "identifier_type" => 3, "identifier" => "B01K0T9772"}
    ])
    pairs = Identifier.where(identifiable: book).pluck(:identifier_type, :value).sort
    assert_equal [["books_work_asin", "B01K0T9772"], ["books_work_isbn10", "0375755349"]], pairs
  end

  test "skips an unknown identifier_type" do
    book = ::Books::Book.create!(title: "Unknown Type Book")
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => 20, "book_id" => book.id, "identifier_type" => 99, "identifier" => "x"}])
    end
  end

  test "fails loud when book_id has no migrated Books::Book" do
    result = run_migrator([{"id" => 9, "book_id" => 999_999, "identifier_type" => 1, "identifier" => "0375755349"}])
    refute result[:success]
    assert_match(/legacy id=9/, result[:error])
  end

  test "is idempotent on the natural key" do
    book = ::Books::Book.create!(title: "Idem GR Book")
    rows = [{"id" => 5, "book_id" => book.id, "identifier_type" => 5, "identifier" => "5527"}]
    run_migrator(rows)
    assert_no_difference -> { Identifier.count } do
      run_migrator(rows)
    end
  end

  test "suppresses search indexing during the load" do
    book = ::Books::Book.create!(title: "Quiet GR Book")
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 6, "book_id" => book.id, "identifier_type" => 5, "identifier" => "42"}])
    end
  end

  test "strips surrounding whitespace from the stored value" do
    book = ::Books::Book.create!(title: "Whitespace Book")
    run_migrator([{"id" => 30, "book_id" => book.id, "identifier_type" => 1, "identifier" => "  0375755349  "}])
    assert_equal "0375755349", Identifier.find_by(identifiable: book).value
  end

  def run_sync(rows, scope)
    m = Services::BooksMigration::BookIdentifierMigrator.new(sync: scope)
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def goodreads_ids(book_id)
    Identifier.where(identifiable_type: "Books::Book", identifiable_id: book_id, identifier_type: :books_work_goodreads_id).pluck(:value)
  end

  test "sync mode adds a new identifier row to a book already here" do
    book = ::Books::Book.create!(id: 90300, title: "Existing Book")

    result = run_sync([
      {"id" => 601, "book_id" => book.id, "identifier_type" => 5, "identifier" => "111"},
      {"id" => 602, "book_id" => book.id, "identifier_type" => 5, "identifier" => "222"}
    ], sync_scope(identifier_ids: [601]))

    assert result[:success], result[:error]
    assert_equal ["111"], goodreads_ids(book.id)
  end

  test "sync mode takes every identifier of a new book, even below the identifier watermark" do
    book = ::Books::Book.create!(id: 90301, title: "New Legacy Book")

    run_sync([{"id" => 10, "book_id" => book.id, "identifier_type" => 5, "identifier" => "333"}], sync_scope(book_ids: [book.id]))

    assert_equal ["333"], goodreads_ids(book.id)
  end

  test "sync mode puts an identifier of a merged book on the survivor" do
    survivor = ::Books::Book.create!(id: 90302, title: "Survivor")

    run_sync([{"id" => 603, "book_id" => 1_301, "identifier_type" => 5, "identifier" => "444"}],
      sync_scope(identifier_ids: [603], redirects: [["Books::Book", 1_301, survivor.id]]))

    assert_equal ["444"], goodreads_ids(survivor.id)
  end

  test "sync mode drops and counts an identifier of a deleted book" do
    result = run_sync([{"id" => 604, "book_id" => 1_302, "identifier_type" => 5, "identifier" => "555"}],
      sync_scope(identifier_ids: [604], redirects: [["Books::Book", 1_302, nil]]))

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:dropped_deleted]
    assert_empty goodreads_ids(1_302)
  end

  test "fails the run naming the legacy row when the book is neither here nor redirected" do
    result = run_sync([{"id" => 605, "book_id" => 1_303, "identifier_type" => 5, "identifier" => "666"}], sync_scope(identifier_ids: [605]))

    refute result[:success]
    assert_includes result[:error], "legacy id=605"
  end
end
