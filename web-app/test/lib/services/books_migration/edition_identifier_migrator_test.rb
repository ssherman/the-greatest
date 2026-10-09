require "test_helper"

class Services::BooksMigration::EditionIdentifierMigratorTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def run_migrator(rows)
    m = Services::BooksMigration::EditionIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "creates a stripped openlibrary id on the mapped new edition" do
    book = ::Books::Book.create!(title: "Ed Book")
    edition = ::Books::Edition.create!(book: book, title: "Ed")
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

  test "sync mode reads only editions of the run's books" do
    in_run = ::Books::Book.create!(id: 90330, title: "In The Run")
    outside = ::Books::Book.create!(id: 90331, title: "Outside")
    e1 = ::Books::Edition.create!(book: in_run, title: "E1")
    e2 = ::Books::Edition.create!(book: outside, title: "E2")
    LegacyIdMap.record(model: "Books::Edition", legacy_id: 930, new_id: e1.id)
    LegacyIdMap.record(model: "Books::Edition", legacy_id: 931, new_id: e2.id)
    m = Services::BooksMigration::EditionIdentifierMigrator.new(sync: sync_scope(book_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => 930, "book_id" => in_run.id, "ol_edition_id" => "/books/OL1M"}],
      [{"id" => 931, "book_id" => outside.id, "ol_edition_id" => "/books/OL2M"}]
    )

    m.call

    assert Identifier.exists?(identifiable_type: "Books::Edition", identifiable_id: e1.id)
    refute Identifier.exists?(identifiable_type: "Books::Edition", identifiable_id: e2.id)
  end
end
