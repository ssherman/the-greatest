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

  test "ignores non-goodreads types (isbn/asin/ean deferred)" do
    book = Books::Book.create!(title: "ISBN Book")
    assert_no_difference -> { Identifier.count } do
      run_migrator([
        {"id" => 2, "book_id" => book.id, "identifier_type" => 1, "identifier" => "0375755349"},
        {"id" => 3, "book_id" => book.id, "identifier_type" => 2, "identifier" => "9780375755347"},
        {"id" => 4, "book_id" => book.id, "identifier_type" => 3, "identifier" => "B01K0T9772"}
      ])
    end
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
