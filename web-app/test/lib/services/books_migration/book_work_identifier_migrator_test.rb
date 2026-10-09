require "test_helper"

class Services::BooksMigration::BookWorkIdentifierMigratorTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def run_migrator(rows)
    m = Services::BooksMigration::BookWorkIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "creates stripped openlibrary and verbatim goodreads ids on the book" do
    book = ::Books::Book.create!(title: "Work Book")
    run_migrator([{"id" => book.id, "ol_work_id" => "/works/OL20600W", "goodreads_id" => "555"}])
    ol = Identifier.find_by(identifiable: book, identifier_type: :books_work_openlibrary_id)
    gr = Identifier.find_by(identifiable: book, identifier_type: :books_work_goodreads_id)
    assert_equal "OL20600W", ol.value
    assert_equal "555", gr.value
  end

  test "creates only the present identifier when a column is nil" do
    book = ::Books::Book.create!(title: "Partial Book")
    run_migrator([{"id" => book.id, "ol_work_id" => "/works/OL99W", "goodreads_id" => nil}])
    assert_equal ["books_work_openlibrary_id"], Identifier.where(identifiable: book).map(&:identifier_type)
  end

  test "is idempotent" do
    book = ::Books::Book.create!(title: "Idem Work Book")
    rows = [{"id" => book.id, "ol_work_id" => "/works/OL1W", "goodreads_id" => "1"}]
    run_migrator(rows)
    assert_no_difference -> { Identifier.count } do
      run_migrator(rows)
    end
  end

  test "book goodreads dedups against an identical book_identifiers goodreads, and coexists when different" do
    book = ::Books::Book.create!(title: "Cross Source Book")
    # book_identifiers type-5 source creates goodreads "123"
    bi = Services::BooksMigration::BookIdentifierMigrator.new
    bi.stubs(:legacy_each).multiple_yields([{"id" => 1, "book_id" => book.id, "identifier_type" => 5, "identifier" => "123"}])
    bi.call
    # same value from books.goodreads_id -> no new row (natural-key dedup)
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => book.id, "ol_work_id" => nil, "goodreads_id" => "123"}])
    end
    # different value from books.goodreads_id -> a second, distinct goodreads row
    assert_difference -> { Identifier.where(identifiable: book, identifier_type: :books_work_goodreads_id).count }, 1 do
      run_migrator([{"id" => book.id, "ol_work_id" => nil, "goodreads_id" => "456"}])
    end
  end

  test "sync mode reads only the run's books" do
    in_run = ::Books::Book.create!(id: 90310, title: "In The Run")
    outside = ::Books::Book.create!(id: 90311, title: "Outside")
    m = Services::BooksMigration::BookWorkIdentifierMigrator.new(sync: sync_scope(book_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => in_run.id, "ol_work_id" => "/works/OL1W", "goodreads_id" => nil}],
      [{"id" => outside.id, "ol_work_id" => "/works/OL2W", "goodreads_id" => nil}]
    )

    m.call

    assert Identifier.exists?(identifiable_type: "Books::Book", identifiable_id: in_run.id)
    refute Identifier.exists?(identifiable_type: "Books::Book", identifiable_id: outside.id)
  end
end
