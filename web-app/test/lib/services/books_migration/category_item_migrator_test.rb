require "test_helper"

class Services::BooksMigration::CategoryItemMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::CategoryItemMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # Create a Books::Category and record its LegacyIdMap entry (as CategoryMigrator would).
  def make_category(legacy_id, deleted: false)
    category = Books::Category.create!(name: "Cat #{legacy_id}", deleted: deleted)
    LegacyIdMap.record(model: "Books::Category", legacy_id: legacy_id, new_id: category.id)
    category
  end

  test "creates a category_item on the mapped category for a Books::Book" do
    category = make_category(8001)
    book = Books::Book.create!(title: "Cat Item Book")
    result = run_migrator([{"id" => 1, "category_id" => 8001, "book_id" => book.id}])
    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    item = CategoryItem.find_by(category_id: category.id, item_id: book.id, item_type: "Books::Book")
    assert_not_nil item
  end

  test "skips a book_category whose category is soft-deleted (absent from the active map)" do
    make_category(8002, deleted: true)
    book = Books::Book.create!(title: "Orphan Item Book")
    assert_no_difference -> { CategoryItem.count } do
      result = run_migrator([{"id" => 2, "category_id" => 8002, "book_id" => book.id}])
      assert result[:success], result[:error]
    end
  end

  test "raises on a book_category whose category was not migrated (missing prerequisite)" do
    book = Books::Book.create!(title: "Unmigrated Cat Book")
    result = run_migrator([{"id" => 8, "category_id" => 424242, "book_id" => book.id}])
    assert_not result[:success]
    assert_match "legacy_id=424242", result[:error]
    assert_match "Books::Category", result[:error]
  end

  test "is idempotent on the (category, item_type, item_id) key" do
    make_category(8003)
    book = Books::Book.create!(title: "Idem Item Book")
    rows = [{"id" => 3, "category_id" => 8003, "book_id" => book.id}]
    run_migrator(rows)
    assert_no_difference -> { CategoryItem.count } do
      run_migrator(rows)
    end
  end

  test "finalize recomputes item_count for a populated Books::Category" do
    category = make_category(8004)
    b1 = Books::Book.create!(title: "IC Book 1")
    b2 = Books::Book.create!(title: "IC Book 2")
    run_migrator([
      {"id" => 4, "category_id" => 8004, "book_id" => b1.id},
      {"id" => 5, "category_id" => 8004, "book_id" => b2.id}
    ])
    assert_equal 2, category.reload.item_count
  end

  test "a soft-deleted category ends up with item_count 0 after finalize" do
    deleted = make_category(8005, deleted: true)
    book = Books::Book.create!(title: "Deleted Cat Book")
    run_migrator([{"id" => 6, "category_id" => 8005, "book_id" => book.id}])
    assert_equal 0, deleted.reload.item_count
  end

  test "suppresses search indexing during the load" do
    make_category(8006)
    book = Books::Book.create!(title: "Quiet Item Book")
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 7, "category_id" => 8006, "book_id" => book.id}])
    end
  end
end
