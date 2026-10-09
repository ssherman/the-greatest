# Test doubles for the books legacy sync. No test opens the legacy connection:
# FakeLegacySource answers the same questions Services::BooksMigration::LegacySource
# asks legacy. Catalog rows are [id, created_at] pairs in id order. user_list_items
# are legacy attribute hashes; review_rows are [id, user_id, book_id, updated_at],
# newest first.
module BooksLegacySyncHelper
  class FakeLegacySource
    def initialize(book_rows: [], author_rows: [], book_identifier_rows: [], book_ids: nil, author_ids: nil,
      category_ids: [], books_updated_count: 0, max_book_identifier_id: 0,
      user_versions: {}, user_list_versions: {}, saved_search_versions: {}, review_rows: [],
      correction_rows: [], reading_goal_ids: [], recommendation_config_count: 0, user_list_items: [],
      saved_search_criteria: [])
      @book_rows = book_rows
      @author_rows = author_rows
      @book_identifier_rows = book_identifier_rows
      @book_ids = book_ids
      @author_ids = author_ids
      @category_ids = category_ids
      @books_updated_count = books_updated_count
      @max_book_identifier_id = max_book_identifier_id
      @user_versions = user_versions
      @user_list_versions = user_list_versions
      @saved_search_versions = saved_search_versions
      @review_rows = review_rows
      @correction_rows = correction_rows
      @reading_goal_ids = reading_goal_ids
      @recommendation_config_count = recommendation_config_count
      @user_list_items = user_list_items
      @saved_search_criteria = saved_search_criteria
    end

    attr_reader :category_ids, :max_book_identifier_id, :user_versions, :user_list_versions,
      :saved_search_versions, :review_rows, :correction_rows, :reading_goal_ids, :recommendation_config_count,
      :saved_search_criteria

    # Same shape and digest as LegacySource's SQL: md5 of the sorted book ids joined by ",".
    def user_list_item_digests
      @user_list_items.group_by { |row| row["user_list_id"] }.transform_values do |rows|
        ids = rows.map { |row| row["book_id"] }.sort
        [ids.size, Digest::MD5.hexdigest(ids.join(","))]
      end
    end

    def user_list_items_for(list_ids) = @user_list_items.select { |row| list_ids.include?(row["user_list_id"]) }

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
  # books_watermark defaults to nothing waiting, so a book that is not here is :missing.
  def sync_scope(book_ids: [], author_ids: [], identifier_ids: [], redirects: [], books_watermark: Float::INFINITY)
    Services::BooksMigration::SyncScope.new(
      book_ids: book_ids.to_set,
      author_ids: author_ids.to_set,
      identifier_ids: identifier_ids.to_set,
      redirects: Services::BooksMigration::Redirects.new(redirects),
      books_watermark: books_watermark
    )
  end
end
