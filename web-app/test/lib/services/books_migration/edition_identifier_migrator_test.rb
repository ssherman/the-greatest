require "test_helper"

class Services::BooksMigration::EditionIdentifierMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::EditionIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "creates a stripped openlibrary id on the mapped new edition" do
    book = Books::Book.create!(title: "Ed Book")
    edition = Books::Edition.create!(book: book, title: "Ed")
    LegacyIdMap.record(model: "Books::Edition", legacy_id: 900, new_id: edition.id)
    run_migrator([{"id" => 900, "ol_edition_id" => "/books/OL25955852M"}])
    idf = Identifier.find_by(identifiable: edition)
    assert_equal "books_edition_openlibrary_id", idf.identifier_type
    assert_equal "OL25955852M", idf.value
  end

  test "skips a legacy edition with no ol_edition_id" do
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => 901, "ol_edition_id" => nil}])
    end
  end

  test "skips when the edition has no id-map entry" do
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => 902, "ol_edition_id" => "/books/OL5M"}])
    end
  end
end
