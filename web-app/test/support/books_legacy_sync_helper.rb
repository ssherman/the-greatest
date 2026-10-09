# Test doubles for the books legacy sync. No test opens the legacy connection:
# FakeLegacySource answers the same questions Services::BooksMigration::LegacySource
# asks legacy. Rows are [id, created_at] pairs in id order.
module BooksLegacySyncHelper
  class FakeLegacySource
    def initialize(book_rows: [], author_rows: [], book_identifier_rows: [], book_ids: nil, author_ids: nil,
      category_ids: [], books_updated_count: 0, max_book_identifier_id: 0)
      @book_rows = book_rows
      @author_rows = author_rows
      @book_identifier_rows = book_identifier_rows
      @book_ids = book_ids
      @author_ids = author_ids
      @category_ids = category_ids
      @books_updated_count = books_updated_count
      @max_book_identifier_id = max_book_identifier_id
    end

    attr_reader :category_ids, :max_book_identifier_id

    def book_rows_above(id) = @book_rows.select { |row_id, _| row_id > id }

    def author_rows_above(id) = @author_rows.select { |row_id, _| row_id > id }

    def book_identifier_rows_above(id) = @book_identifier_rows.select { |row_id, _| row_id > id }

    def book_ids = @book_ids || @book_rows.map(&:first)

    def author_ids = @author_ids || @author_rows.map(&:first)

    def books_updated_since(_time, through_id:) = @books_updated_count
  end

  def init_watermarks(books:, authors:, book_identifiers:)
    {"books" => books, "authors" => authors, "book_identifiers" => book_identifiers}.each do |key, value|
      LegacySyncWatermark.create!(key: key, value: value)
    end
  end

  # redirects: rows for Services::BooksMigration::Redirects.new, [[item_type, from_id, to_id], ...]
  def sync_scope(book_ids: [], author_ids: [], identifier_ids: [], redirects: [])
    Services::BooksMigration::SyncScope.new(
      book_ids: book_ids.to_set,
      author_ids: author_ids.to_set,
      identifier_ids: identifier_ids.to_set,
      redirects: Services::BooksMigration::Redirects.new(redirects)
    )
  end
end
