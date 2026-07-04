require "test_helper"

class Services::BooksMigration::BookAuthorMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    migrator = Services::BooksMigration::BookAuthorMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "creates book_authors on the natural key with no search flood" do
    author = Books::Author.create!(name: "Link Author")
    book = Books::Book.create!(title: "Link Book")

    assert_no_difference -> { SearchIndexRequest.count } do
      result = run_migrator([{"book_id" => book.id, "author_id" => author.id, "position" => 1}])
      assert result[:success], result[:error]
      assert_equal 1, result[:data][:count]
    end

    ba = Books::BookAuthor.find_by(book_id: book.id, author_id: author.id)
    assert_equal 1, ba.position
    assert_equal "author", ba.role
  end

  test "is idempotent on the [book_id, author_id] natural key" do
    author = Books::Author.create!(name: "Idem Author")
    book = Books::Book.create!(title: "Idem Book")
    rows = [{"book_id" => book.id, "author_id" => author.id, "position" => 2}]
    run_migrator(rows)
    assert_no_difference -> { Books::BookAuthor.count } do
      run_migrator(rows)
    end
  end
end
