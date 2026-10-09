require "test_helper"

class Services::BooksMigration::BookAuthorMigratorTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def run_migrator(rows)
    migrator = Services::BooksMigration::BookAuthorMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "creates book_authors on the natural key with no search flood" do
    author = ::Books::Author.create!(name: "Link Author")
    book = ::Books::Book.create!(title: "Link Book")

    assert_no_difference -> { SearchIndexRequest.count } do
      result = run_migrator([{"book_id" => book.id, "author_id" => author.id, "position" => 1}])
      assert result[:success], result[:error]
      assert_equal 1, result[:data][:count]
    end

    ba = ::Books::BookAuthor.find_by(book_id: book.id, author_id: author.id)
    assert_equal 1, ba.position
    assert_equal "author", ba.role
  end

  test "is idempotent on the [book_id, author_id] natural key" do
    author = ::Books::Author.create!(name: "Idem Author")
    book = ::Books::Book.create!(title: "Idem Book")
    rows = [{"book_id" => book.id, "author_id" => author.id, "position" => 2}]
    run_migrator(rows)
    assert_no_difference -> { ::Books::BookAuthor.count } do
      run_migrator(rows)
    end
  end

  def run_sync(rows, scope)
    m = Services::BooksMigration::BookAuthorMigrator.new(sync: scope)
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "sync mode links a new book to the survivor of its merged author" do
    book = ::Books::Book.create!(id: 90100, title: "New Legacy Book")
    survivor = books_authors(:king)

    result = run_sync([{"book_id" => book.id, "author_id" => 1_201, "position" => 1}],
      sync_scope(book_ids: [book.id], redirects: [["Books::Author", 1_201, survivor.id]]))

    assert result[:success], result[:error]
    assert ::Books::BookAuthor.exists?(book_id: book.id, author_id: survivor.id)
  end

  test "sync mode drops and counts a link to a deleted author" do
    book = ::Books::Book.create!(id: 90101, title: "New Legacy Book")

    result = run_sync([{"book_id" => book.id, "author_id" => 1_202, "position" => 1}],
      sync_scope(book_ids: [book.id], redirects: [["Books::Author", 1_202, nil]]))

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:dropped_deleted]
    assert_empty ::Books::BookAuthor.where(book_id: book.id)
  end

  test "sync mode ignores links of books outside the run and keeps an existing link as it is" do
    in_run = ::Books::Book.create!(id: 90102, title: "In The Run")
    existing = ::Books::Book.create!(id: 90103, title: "Already Here")
    author = books_authors(:king)
    ::Books::BookAuthor.create!(book: in_run, author: author, position: 3)

    result = run_sync([
      {"book_id" => in_run.id, "author_id" => author.id, "position" => 1},
      {"book_id" => existing.id, "author_id" => author.id, "position" => 1}
    ], sync_scope(book_ids: [in_run.id]))

    assert result[:success], result[:error]
    assert_equal 3, ::Books::BookAuthor.find_by!(book_id: in_run.id, author_id: author.id).position
    refute ::Books::BookAuthor.exists?(book_id: existing.id)
  end

  test "fails the run naming the legacy row when the author is neither here nor redirected" do
    book = ::Books::Book.create!(id: 90104, title: "Orphan Risk")

    result = run_sync([{"id" => 77, "book_id" => book.id, "author_id" => 1_203, "position" => 1}], sync_scope(book_ids: [book.id]))

    refute result[:success]
    assert_includes result[:error], "legacy id=77"
  end
end
