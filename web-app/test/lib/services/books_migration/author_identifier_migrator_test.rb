require "test_helper"

class Services::BooksMigration::AuthorIdentifierMigratorTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def run_migrator(rows)
    m = Services::BooksMigration::AuthorIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "creates a stripped openlibrary id on the author" do
    author = ::Books::Author.create!(name: "OL Author")
    run_migrator([{"id" => author.id, "ol_author_id" => "/authors/OL9100206A"}])
    idf = Identifier.find_by(identifiable: author)
    assert_equal "books_author_openlibrary_id", idf.identifier_type
    assert_equal "OL9100206A", idf.value
  end

  test "skips authors with no ol_author_id" do
    author = ::Books::Author.create!(name: "No OL Author")
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => author.id, "ol_author_id" => nil}])
    end
  end

  test "is idempotent" do
    author = ::Books::Author.create!(name: "Idem OL Author")
    rows = [{"id" => author.id, "ol_author_id" => "/authors/OL1A"}]
    run_migrator(rows)
    assert_no_difference -> { Identifier.count } do
      run_migrator(rows)
    end
  end

  test "sync mode reads only the run's authors" do
    in_run = ::Books::Author.create!(id: 90320, name: "In The Run")
    outside = ::Books::Author.create!(id: 90321, name: "Outside")
    m = Services::BooksMigration::AuthorIdentifierMigrator.new(sync: sync_scope(author_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => in_run.id, "ol_author_id" => "/authors/OL1A"}],
      [{"id" => outside.id, "ol_author_id" => "/authors/OL2A"}]
    )

    m.call

    assert Identifier.exists?(identifiable_type: "Books::Author", identifiable_id: in_run.id)
    refute Identifier.exists?(identifiable_type: "Books::Author", identifiable_id: outside.id)
  end
end
