require "test_helper"

class Services::BooksMigration::CategoryMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::CategoryMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy(id, overrides = {})
    {
      "id" => id, "name" => "Cat #{id}", "description" => nil,
      "category_type" => 0, "import_source" => 1, "deleted" => false,
      "slug" => "cat-#{id}-slug", "merged_category_names" => [],
      "parent_category_id" => nil
    }.merge(overrides)
  end

  test "creates a Books::Category with a fresh id, records the map, decodes enums" do
    result = run_migrator([legacy(9001)])
    assert result[:success], result[:error]
    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9001)
    assert_not_nil new_id
    category = Books::Category.find(new_id)
    assert_equal "Cat 9001", category.name
    assert_equal "Books::Category", category.type
    assert_equal "genre", category.category_type
    assert_equal "open_library", category.import_source
  end

  test "preserves the legacy slug verbatim instead of regenerating from the name" do
    run_migrator([legacy(9002, "name" => "Speculative Fiction", "slug" => "metaphysical-visionary-fiction")])
    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9002)
    assert_equal "metaphysical-visionary-fiction", Books::Category.find(new_id).slug
  end

  test "migrates a soft-deleted category with the deleted flag set" do
    run_migrator([legacy(9003, "deleted" => true)])
    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9003)
    assert Books::Category.find(new_id).deleted
  end

  test "maps merged_category_names onto alternative_names" do
    run_migrator([legacy(9004, "merged_category_names" => ["Alt A", "Alt B"])])
    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9004)
    assert_equal ["Alt A", "Alt B"], Books::Category.find(new_id).alternative_names
  end

  test "is idempotent: re-running updates in place, keeps the map, and keeps the slug" do
    run_migrator([legacy(9005, "name" => "V1")])
    first_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9005)
    assert_no_difference -> { Books::Category.count } do
      run_migrator([legacy(9005, "name" => "V2")])
    end
    assert_equal first_id, LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9005)
    reloaded = Books::Category.find(first_id)
    assert_equal "V2", reloaded.name
    assert_equal "cat-9005-slug", reloaded.slug
  end

  test "remaps the self-referential parent_id through the id map in finalize" do
    run_migrator([
      legacy(9006, "name" => "Parent"),
      legacy(9007, "name" => "Child", "parent_category_id" => 9006)
    ])
    parent_new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9006)
    child_new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9007)
    assert_equal parent_new_id, Books::Category.find(child_new_id).parent_id
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([legacy(9008)])
    end
  end
end
