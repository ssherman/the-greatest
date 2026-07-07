require "test_helper"

class Services::BooksMigration::BookIdentifierMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::BookIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "migrates goodreads (type 5) as a work-level goodreads id on the book" do
    book = Books::Book.create!(title: "GR Book")
    result = run_migrator([{"id" => 1, "book_id" => book.id, "identifier_type" => 5, "identifier" => "1079398"}])
    assert result[:success], result[:error]
    idf = Identifier.find_by(identifiable: book)
    assert_equal "books_work_goodreads_id", idf.identifier_type
    assert_equal "1079398", idf.value
  end

  test "migrates isbn10 (type 1), isbn13 (type 2), ean13 (type 4) as work-level ids" do
    book = Books::Book.create!(title: "ISBN Book")
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
    book = Books::Book.create!(title: "ASIN Book")
    run_migrator([
      {"id" => 7, "book_id" => book.id, "identifier_type" => 3, "identifier" => "0375755349"},
      {"id" => 8, "book_id" => book.id, "identifier_type" => 3, "identifier" => "B01K0T9772"}
    ])
    pairs = Identifier.where(identifiable: book).pluck(:identifier_type, :value).sort
    assert_equal [["books_work_asin", "B01K0T9772"], ["books_work_isbn10", "0375755349"]], pairs
  end

  test "skips an unknown identifier_type" do
    book = Books::Book.create!(title: "Unknown Type Book")
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
    book = Books::Book.create!(title: "Idem GR Book")
    rows = [{"id" => 5, "book_id" => book.id, "identifier_type" => 5, "identifier" => "5527"}]
    run_migrator(rows)
    assert_no_difference -> { Identifier.count } do
      run_migrator(rows)
    end
  end

  test "suppresses search indexing during the load" do
    book = Books::Book.create!(title: "Quiet GR Book")
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 6, "book_id" => book.id, "identifier_type" => 5, "identifier" => "42"}])
    end
  end
end
