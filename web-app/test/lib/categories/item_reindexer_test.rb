require "test_helper"

class Categories::ItemReindexerTest < ActiveSupport::TestCase
  def setup
    @category = categories(:books_novels_genre)
    # The three books_novels_genre fixtures each fired CategoryItem's own
    # after_save when the fixtures loaded; start from a clean slate so the
    # counts below measure only what the service inserted.
    SearchIndexRequest.where(parent_type: "Books::Book").delete_all
  end

  test "queues one index_item request per category item" do
    result = Categories::ItemReindexer.call(category: @category)

    book_ids = CategoryItem.where(category_id: @category.id, item_type: "Books::Book").pluck(:item_id)
    assert_equal 3, book_ids.size, "fixture drift: books_novels_genre should hold 3 books"

    queued = SearchIndexRequest.where(parent_type: "Books::Book", action: :index_item).pluck(:parent_id)
    assert_equal book_ids.sort, queued.sort
    assert result.success?
    assert_equal 3, result.data[:queued]
    assert_empty result.errors
  end

  test "queues index_item, never unindex_item" do
    Categories::ItemReindexer.call(category: @category)

    # Scoped to Books::Book, like every other assertion in this file: unrelated
    # scaffold fixtures (search_index_requests.yml's "one"/"two", parent_type
    # "Parent") carry action: unindex_item and would otherwise leak into an
    # unscoped count.
    assert_equal 0, SearchIndexRequest.where(parent_type: "Books::Book", action: :unindex_item).count
  end

  test "queues nothing while migration suppression is active" do
    assert_no_difference -> { SearchIndexRequest.count } do
      Services::BooksMigration.without_search_indexing do
        result = Categories::ItemReindexer.call(category: @category)
        assert result.success?
        assert_equal 0, result.data[:queued]
        assert result.data[:suppressed]
      end
    end
  end

  test "skips item types the indexer does not drain" do
    # Books::Series has as_indexed_json but is absent from
    # Search::IndexerJob::INDEXED_MODEL_TYPES, so a request for one would never
    # be drained and would sit in the queue forever.
    assert_not_includes Search::IndexerJob::INDEXED_MODEL_TYPES, "Books::Series"

    series = books_series(:asoiaf)
    CategoryItem.create!(category: @category, item: series)
    SearchIndexRequest.delete_all

    Categories::ItemReindexer.call(category: @category)

    assert_equal 0, SearchIndexRequest.where(parent_type: "Books::Series").count
  end

  test "inserts across the batch boundary" do
    # Mocha, not stub_const: Minitest 6 has no stub_const and minitest/mock is a
    # separate gem this app does not use. The service reads self.class.batch_size
    # rather than the constant so this stub can reach it.
    Categories::ItemReindexer.stubs(:batch_size).returns(2)

    Categories::ItemReindexer.call(category: @category)

    assert_equal 3, SearchIndexRequest.where(parent_type: "Books::Book").count
  end

  test "returns a zero result for a category with no items" do
    empty = categories(:books_nonfiction_genre)
    assert_equal 0, CategoryItem.where(category_id: empty.id).count, "fixture drift: expected no items"

    result = Categories::ItemReindexer.call(category: empty)

    assert result.success?
    assert_equal 0, result.data[:queued]
  end
end
