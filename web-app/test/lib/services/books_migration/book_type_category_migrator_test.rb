# frozen_string_literal: true

require "test_helper"

class Services::BooksMigration::BookTypeCategoryMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::BookTypeCategoryMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # preload_context resolves ALL FOUR target categories up front and raises if any
  # is unmapped, so every test needs all four mapped -- not just the one it exercises.
  setup do
    @book = books_books(:war_and_peace)
    @categories = Services::BooksMigration::BookTypeCategoryMigrator::LEGACY_CATEGORY_IDS
      .each_with_object({}) do |(book_type, legacy_id), map|
        category = ::Books::Category.create!(name: "Type Target #{book_type}", category_type: :genre)
        LegacyIdMap.record(model: "Books::Category", legacy_id: legacy_id, new_id: category.id)
        map[book_type] = category
      end
    @fiction = @categories[0]
  end

  test "links a fiction book to the Fiction category" do
    result = run_migrator([{"id" => @book.id, "book_type" => 0}])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal "CategoryItem", result[:data][:model]
    assert CategoryItem.exists?(
      category_id: @fiction.id, item_type: "Books::Book", item_id: @book.id
    )
  end

  test "skips a book whose book_type is null" do
    result = run_migrator([{"id" => @book.id, "book_type" => nil}])

    assert result[:success], result[:error]
    assert_equal 0, result[:data][:count]
  end

  test "is idempotent against an existing link" do
    CategoryItem.create!(category: @fiction, item: @book)
    result = run_migrator([{"id" => @book.id, "book_type" => 0}])

    assert result[:success], result[:error]
    assert_equal 1, CategoryItem.where(
      category_id: @fiction.id, item_type: "Books::Book", item_id: @book.id
    ).count
  end

  test "raises when any target category has no LegacyIdMap entry" do
    # Missing prerequisite: the categories migrator has not run. Failing loud
    # beats silently producing a success-looking low count. It raises before any
    # write, even for a book_type whose own category IS mapped.
    LegacyIdMap.where(model: "Books::Category", legacy_id: 40876).delete_all

    result = run_migrator([{"id" => @book.id, "book_type" => 0}])

    refute result[:success]
    assert_match(/LegacyIdMap for Books::Category legacy_id=40876/, result[:error])
    refute CategoryItem.exists?(category_id: @fiction.id, item_type: "Books::Book", item_id: @book.id)
  end

  test "recomputes item_count for the affected categories" do
    run_migrator([{"id" => @book.id, "book_type" => 0}])

    assert_equal 1, @fiction.reload.item_count
  end

  test "does not queue search index requests" do
    SearchIndexRequest.delete_all
    run_migrator([{"id" => @book.id, "book_type" => 0}])

    assert_equal 0, SearchIndexRequest.count
  end
end
