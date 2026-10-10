require "test_helper"

class Services::BooksMigration::SavedSearchMigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper
  include SequenceIsolation

  isolate_sequences "saved_searches"

  setup do
    @user = users(:regular_user)
    @genre = ::Books::Category.create!(name: "Kept Genre", category_type: :genre)
    LegacyIdMap.record(model: "Books::Category", legacy_id: 31, new_id: @genre.id)
    LegacyIdMap.record(model: "Books::Category", legacy_id: 32, new_id: 999_999_999) # deleted here
  end

  def legacy_search(id, criteria = {"genre_match_mode" => "any"})
    {
      "id" => id, "user_id" => @user.id, "name" => "Search #{id}", "description" => nil,
      "criteria" => criteria.to_json, "public" => false, "last_executed_at" => nil, "result_count" => nil,
      "created_at" => Time.utc(2025, 1, 1), "updated_at" => Time.utc(2025, 2, 1)
    }
  end

  def run_migrator(rows, sync: sync_scope)
    migrator = Services::BooksMigration::SavedSearchMigrator.new(sync: sync)
    stub = migrator.stubs(:legacy_each)
    stub.multiple_yields(*rows.zip) if rows.any?
    migrator.call
  end

  def here_search(id)
    ::Books::SavedSearch.create!(id: id, user: @user, name: "Here #{id}", criteria: {"genre_match_mode" => "any"})
  end

  test "removes a category deleted here from the criteria and counts it" do
    result = run_migrator([legacy_search(15_001, {"included_category_ids" => ["31", "32"]})], sync: nil)

    assert result[:success], result[:error]
    assert_equal [@genre.id], ::Books::SavedSearch.find(15_001).criteria["included_category_ids"]
    assert_equal 1, result[:data][:categories_removed]
  end

  test "still raises on a legacy category with no map entry" do
    result = run_migrator([legacy_search(15_001, {"included_category_ids" => ["33"]})], sync: nil)

    refute result[:success]
    assert_includes result[:error], "no LegacyIdMap for Books::Category legacy_id=33"
  end

  test "deletes a legacy-origin books search legacy no longer has" do
    here_search(15_002)

    result = run_migrator([legacy_search(15_001)])

    assert result[:success], result[:error]
    refute ::SavedSearch.exists?(15_002)
    assert_equal({inserted: 1, deleted: 1}, result[:data].slice(:inserted, :deleted))
  end

  test "leaves new-app searches alone" do
    new_app = here_search(20_001)

    run_migrator([])

    assert ::SavedSearch.exists?(new_app.id)
  end

  test "refuses past the deletion guard and deletes nothing" do
    here_search(15_002)
    Services::BooksMigration.expects(:guard_deletion!).with("saved_searches", 1, 1).raises(RuntimeError, "would delete 1 of 1")

    result = run_migrator([])

    refute result[:success]
    assert ::SavedSearch.exists?(15_002)
  end

  test "the full migration deletes nothing" do
    here_search(15_002)

    result = run_migrator([legacy_search(15_001)], sync: nil)

    assert result[:success], result[:error]
    assert ::SavedSearch.exists?(15_002)
  end
end
