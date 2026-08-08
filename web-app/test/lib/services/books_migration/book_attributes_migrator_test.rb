# frozen_string_literal: true

require "test_helper"

class Services::BooksMigration::BookAttributesMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::BookAttributesMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy_row(overrides = {})
    {
      "id" => @book.id,
      "book_length" => 2,
      "page_range" => "251-350",
      "word_count" => 90_000
    }.merge(overrides)
  end

  setup do
    @book = books_books(:war_and_peace)
    @book.update_columns(book_length: nil, page_range: nil, word_count: nil)
  end

  test "copies all three attributes onto the existing book" do
    result = run_migrator([legacy_row])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal "Books::Book", result[:data][:model]

    @book.reload
    assert_equal "medium", @book.book_length
    assert_equal "251-350", @book.page_range
    assert_equal 90_000, @book.word_count
  end

  test "copies the legacy book_length verbatim rather than re-deriving it" do
    # 251-350 would derive to medium(2); legacy says long(4). Legacy wins, because
    # migrated searches must match legacy results exactly.
    run_migrator([legacy_row("book_length" => 4)])

    assert_equal "long", @book.reload.book_length
  end

  test "copies a null book_length even when a page_range is present" do
    # 1,136 legacy books have a source but no stored length. Re-deriving them
    # here would change what their saved searches return.
    run_migrator([legacy_row("book_length" => nil, "page_range" => "xii-300")])

    @book.reload
    assert_nil @book.book_length
    assert_equal "xii-300", @book.page_range
  end

  test "leaves other columns untouched" do
    title = @book.title
    run_migrator([legacy_row])

    assert_equal title, @book.reload.title
  end

  test "ignores a legacy book with no counterpart in the new database" do
    # The UPDATE simply matches no rows. It must not raise, and must not touch
    # any other book -- a WHERE clause bug here would silently rewrite the corpus.
    before = Books::Book.where.not(book_length: nil).count

    result = run_migrator([legacy_row("id" => 999_999_999)])

    assert result[:success], result[:error]
    assert_equal before, Books::Book.where.not(book_length: nil).count
    assert_nil @book.reload.book_length
  end

  test "is idempotent" do
    rows = [legacy_row]
    run_migrator(rows)
    result = run_migrator(rows)

    assert result[:success], result[:error]
    assert_equal "medium", @book.reload.book_length
  end

  test "does not queue search index requests" do
    SearchIndexRequest.delete_all
    run_migrator([legacy_row])

    assert_equal 0, SearchIndexRequest.count
  end
end
