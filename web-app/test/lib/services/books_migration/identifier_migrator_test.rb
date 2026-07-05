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
end
