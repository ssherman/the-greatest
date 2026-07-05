require "test_helper"

class Services::BooksMigration::AuthorIdentifierMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::AuthorIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "creates a stripped openlibrary id on the author" do
    author = Books::Author.create!(name: "OL Author")
    run_migrator([{"id" => author.id, "ol_author_id" => "/authors/OL9100206A"}])
    idf = Identifier.find_by(identifiable: author)
    assert_equal "books_author_openlibrary_id", idf.identifier_type
    assert_equal "OL9100206A", idf.value
  end

  test "skips authors with no ol_author_id" do
    author = Books::Author.create!(name: "No OL Author")
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => author.id, "ol_author_id" => nil}])
    end
  end
end
