require "test_helper"

class Services::BooksMigration::CategoryItemMigratorTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def run_migrator(rows)
    m = Services::BooksMigration::CategoryItemMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # Create a Books::Category and record its LegacyIdMap entry (as CategoryMigrator would).
  def make_category(legacy_id, deleted: false)
    category = ::Books::Category.create!(name: "Cat #{legacy_id}", deleted: deleted)
    LegacyIdMap.record(model: "Books::Category", legacy_id: legacy_id, new_id: category.id)
    category
  end

  test "creates a category_item on the mapped category for a Books::Book" do
    category = make_category(8001)
    book = ::Books::Book.create!(title: "Cat Item Book")
    result = run_migrator([{"id" => 1, "category_id" => 8001, "book_id" => book.id}])
    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    item = CategoryItem.find_by(category_id: category.id, item_id: book.id, item_type: "Books::Book")
    assert_not_nil item
  end

  test "skips a book_category whose category is soft-deleted (absent from the active map)" do
    make_category(8002, deleted: true)
    book = ::Books::Book.create!(title: "Orphan Item Book")
    assert_no_difference -> { CategoryItem.count } do
      result = run_migrator([{"id" => 2, "category_id" => 8002, "book_id" => book.id}])
      assert result[:success], result[:error]
    end
  end

  test "raises on a book_category whose category was not migrated (missing prerequisite)" do
    book = ::Books::Book.create!(title: "Unmigrated Cat Book")
    result = run_migrator([{"id" => 8, "category_id" => 424242, "book_id" => book.id}])
    assert_not result[:success]
    assert_match "legacy_id=424242", result[:error]
    assert_match "Books::Category", result[:error]
  end

  test "is idempotent on the (category, item_type, item_id) key" do
    make_category(8003)
    book = ::Books::Book.create!(title: "Idem Item Book")
    rows = [{"id" => 3, "category_id" => 8003, "book_id" => book.id}]
    run_migrator(rows)
    assert_no_difference -> { CategoryItem.count } do
      run_migrator(rows)
    end
  end

  test "finalize recomputes item_count for a populated Books::Category" do
    category = make_category(8004)
    b1 = ::Books::Book.create!(title: "IC Book 1")
    b2 = ::Books::Book.create!(title: "IC Book 2")
    run_migrator([
      {"id" => 4, "category_id" => 8004, "book_id" => b1.id},
      {"id" => 5, "category_id" => 8004, "book_id" => b2.id}
    ])
    assert_equal 2, category.reload.item_count
  end

  test "a soft-deleted category ends up with item_count 0 after finalize" do
    deleted = make_category(8005, deleted: true)
    book = ::Books::Book.create!(title: "Deleted Cat Book")
    run_migrator([{"id" => 6, "category_id" => 8005, "book_id" => book.id}])
    assert_equal 0, deleted.reload.item_count
  end

  test "suppresses search indexing during the load" do
    make_category(8006)
    book = ::Books::Book.create!(title: "Quiet Item Book")
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 7, "category_id" => 8006, "book_id" => book.id}])
    end
  end

  test "sync mode writes items of the run's books only" do
    category = make_category(8101)
    in_run = ::Books::Book.create!(title: "In The Run")
    outside = ::Books::Book.create!(title: "Outside")
    m = Services::BooksMigration::CategoryItemMigrator.new(sync: sync_scope(book_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => 1, "category_id" => 8101, "book_id" => in_run.id}],
      [{"id" => 2, "category_id" => 8101, "book_id" => outside.id}]
    )

    m.call

    assert CategoryItem.exists?(category_id: category.id, item_id: in_run.id)
    refute CategoryItem.exists?(category_id: category.id, item_id: outside.id)
  end

  test "drops a book_category whose mapped category no longer exists here" do
    category = make_category(8102)
    ::Books::Category.where(id: category.id).delete_all
    book = ::Books::Book.create!(title: "Gone Category Book")

    result = run_migrator([{"id" => 9, "category_id" => 8102, "book_id" => book.id}])

    assert result[:success], result[:error]
    assert_empty CategoryItem.where(item_id: book.id, item_type: "Books::Book")
  end

  test "a link to a category merged here lands on the merge target" do
    target = ::Books::Category.create!(name: "Target Cat")
    merged = make_category(8101, deleted: true)
    merged.update_columns(merged_into_id: target.id)
    book = ::Books::Book.create!(title: "Merged Link Book")

    result = run_migrator([{"id" => 11, "category_id" => 8101, "book_id" => book.id}])

    assert result[:success], result[:error]
    assert CategoryItem.exists?(category_id: target.id, item_id: book.id, item_type: "Books::Book")
  end

  test "two legacy categories merged into one target on the same book do not collide" do
    target = ::Books::Category.create!(name: "Shared Target")
    [8102, 8103].each { |legacy_id| make_category(legacy_id, deleted: true).update_columns(merged_into_id: target.id) }
    book = ::Books::Book.create!(title: "Double Merge Book")

    result = run_migrator([
      {"id" => 12, "category_id" => 8102, "book_id" => book.id},
      {"id" => 13, "category_id" => 8103, "book_id" => book.id}
    ])

    assert result[:success], result[:error]
    assert_equal 1, CategoryItem.where(category_id: target.id, item_id: book.id).count
  end

  test "a link to a category merged into a target later deleted as junk is dropped" do
    junk = ::Books::Category.create!(name: "Junk Target", deleted: true)
    make_category(8104, deleted: true).update_columns(merged_into_id: junk.id)
    book = ::Books::Book.create!(title: "Junk Merge Book")

    assert_no_difference -> { CategoryItem.count } do
      result = run_migrator([{"id" => 14, "category_id" => 8104, "book_id" => book.id}])
      assert result[:success], result[:error]
    end
  end

  test "a new row is written as legacy" do
    category = make_category(8201)
    book = ::Books::Book.create!(title: "New Row Book")
    run_migrator([{"id" => 1, "category_id" => 8201, "book_id" => book.id}])
    assert CategoryItem.find_by!(category: category, item: book).source_legacy?
  end

  test "an existing inherited row is promoted to legacy when legacy supplies it" do
    category = make_category(8202)
    book = ::Books::Book.create!(title: "Inherited Book")
    CategoryItem.create!(category: category, item: book, source: :inherited)
    run_migrator([{"id" => 1, "category_id" => 8202, "book_id" => book.id}])
    assert CategoryItem.find_by!(category: category, item: book).source_legacy?
  end

  test "an existing admin row stays admin" do
    category = make_category(8203)
    book = ::Books::Book.create!(title: "Admin Book")
    CategoryItem.create!(category: category, item: book, source: :admin)
    run_migrator([{"id" => 1, "category_id" => 8203, "book_id" => book.id}])
    assert CategoryItem.find_by!(category: category, item: book).source_admin?
  end

  def split_into(sf, fantasy, legacy_id:)
    combined = make_category(legacy_id)
    combined.update!(deleted: true, merged_into: sf)
    CategoryCleanupDecision.create!(category: combined, run: "g1", stage: "genres", action: :split, decided_by: :ai,
      status: :applied, target_category: sf, extra_target_ids: [fantasy.id], category_snapshot: {})
    combined
  end

  test "a link to a split genre also lands on its extra targets" do
    sf = ::Books::Category.create!(name: "Science Fiction")
    fantasy = ::Books::Category.create!(name: "Fantasy")
    split_into(sf, fantasy, legacy_id: 8101)
    book = ::Books::Book.create!(title: "Split Link Book")

    result = run_migrator([{"id" => 11, "category_id" => 8101, "book_id" => book.id}])

    assert result[:success], result[:error]
    assert CategoryItem.exists?(category: sf, item_id: book.id, item_type: "Books::Book")
    assert CategoryItem.exists?(category: fantasy, item_id: book.id, item_type: "Books::Book")
  end

  test "an extra target that has since been deleted is skipped" do
    sf = ::Books::Category.create!(name: "Science Fiction")
    fantasy = ::Books::Category.create!(name: "Fantasy", deleted: true)
    split_into(sf, fantasy, legacy_id: 8102)
    book = ::Books::Book.create!(title: "Split Link Book 2")

    run_migrator([{"id" => 12, "category_id" => 8102, "book_id" => book.id}])

    assert CategoryItem.exists?(category: sf, item_id: book.id, item_type: "Books::Book")
    refute CategoryItem.exists?(category: fantasy, item_id: book.id, item_type: "Books::Book")
  end

  test "a kept genre with also links its extra genres" do
    romantasy = make_category(8103)
    romance = ::Books::Category.create!(name: "Romance")
    CategoryCleanupDecision.create!(category: romantasy, run: "g1", stage: "genres", action: :keep, decided_by: :ai,
      status: :applied, extra_target_ids: [romance.id], category_snapshot: {})
    book = ::Books::Book.create!(title: "Romantasy Book")

    run_migrator([{"id" => 13, "category_id" => 8103, "book_id" => book.id}])

    assert CategoryItem.exists?(category: romantasy, item_id: book.id, item_type: "Books::Book")
    assert CategoryItem.exists?(category: romance, item_id: book.id, item_type: "Books::Book")
  end
end
