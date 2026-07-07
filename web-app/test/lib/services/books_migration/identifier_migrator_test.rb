require "test_helper"

class Services::BooksMigration::IdentifierMigratorTest < ActiveSupport::TestCase
  M = Services::BooksMigration::IdentifierMigrator

  test "strip_openlibrary_key reduces an OL path to the bare key" do
    assert_equal "OL20600W", M.strip_openlibrary_key("/works/OL20600W")
    assert_equal "OL9100206A", M.strip_openlibrary_key("/authors/OL9100206A")
    assert_equal "OL25955852M", M.strip_openlibrary_key("/books/OL25955852M")
  end

  test "strip_openlibrary_key passes through a bare key and maps blank/nil to nil" do
    assert_equal "OL20600W", M.strip_openlibrary_key("OL20600W")
    assert_nil M.strip_openlibrary_key(nil)
    assert_nil M.strip_openlibrary_key("")
  end

  test "asin_identifier_type maps an ISBN-10-shaped value to isbn10" do
    assert_equal :books_work_isbn10, M.asin_identifier_type("0375755349")
    assert_equal :books_work_isbn10, M.asin_identifier_type("037575534X")
    assert_equal :books_work_isbn10, M.asin_identifier_type("037575534x")
    assert_equal :books_work_isbn10, M.asin_identifier_type("  0375755349  ")
  end

  test "asin_identifier_type keeps a real Amazon (Kindle) ASIN as asin" do
    assert_equal :books_work_asin, M.asin_identifier_type("B01K0T9772")
    assert_equal :books_work_asin, M.asin_identifier_type("B09LVX2Y9V")
  end

  test "asin_identifier_type defaults blank/short/long values to asin" do
    assert_equal :books_work_asin, M.asin_identifier_type(nil)
    assert_equal :books_work_asin, M.asin_identifier_type("")
    assert_equal :books_work_asin, M.asin_identifier_type("12345")
    assert_equal :books_work_asin, M.asin_identifier_type("9780375755347")
  end
end
