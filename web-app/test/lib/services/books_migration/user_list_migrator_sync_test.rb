require "test_helper"

class Services::BooksMigration::UserListMigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  setup do
    @user = users(:regular_user)
    @kept = ::Books::UserList.create!(id: 500, user: @user, name: "Kept", list_type: :custom)
    @gone = ::Books::UserList.create!(id: 501, user: @user, name: "Deleted On Legacy", list_type: :custom)
    UserListItem.create!(user_list: @gone, listable: ::Books::Book.create!(title: "On A Gone List"), position: 1)
  end

  def legacy_list(id, overrides = {})
    {
      "id" => id, "user_id" => @user.id, "name" => "Legacy #{id}", "description" => nil, "list_type" => 4,
      "view_mode" => nil, "public" => true, "position" => 1,
      "created_at" => Time.utc(2025, 1, 1), "updated_at" => Time.utc(2025, 2, 1)
    }.merge(overrides)
  end

  def run_migrator(rows, sync: sync_scope)
    migrator = Services::BooksMigration::UserListMigrator.new(sync: sync)
    stub = migrator.stubs(:legacy_each)
    stub.multiple_yields(*rows.zip) if rows.any?
    migrator.call
  end

  test "deletes a legacy-origin books list legacy no longer has, with its items" do
    result = run_migrator([legacy_list(500)])

    assert result[:success], result[:error]
    refute ::UserList.exists?(501)
    refute UserListItem.exists?(user_list_id: 501)
    assert_equal({inserted: 0, deleted: 1, items_deleted: 1}, result[:data].slice(:inserted, :deleted, :items_deleted))
  end

  test "overwrites a list legacy still has" do
    run_migrator([legacy_list(500, "name" => "Renamed On Legacy"), legacy_list(501)])

    assert_equal "Renamed On Legacy", @kept.reload.name
  end

  test "leaves new-app lists and other domains' lists alone" do
    new_app = ::Books::UserList.create!(id: 1_000_500, user: @user, name: "New App", list_type: :custom)
    games = ::Games::UserList.create!(id: 502, user: @user, name: "Games", list_type: :custom)

    result = run_migrator([legacy_list(500), legacy_list(501)])

    assert result[:success], result[:error]
    assert ::UserList.exists?(new_app.id)
    assert ::UserList.exists?(games.id)
  end

  test "counts what it inserts" do
    result = run_migrator([legacy_list(500), legacy_list(501), legacy_list(503)])

    assert_equal({inserted: 1, deleted: 0}, result[:data].slice(:inserted, :deleted))
  end

  test "refuses past the deletion guard and deletes nothing" do
    Services::BooksMigration.expects(:guard_deletion!).with("user_lists", 1, 2).raises(RuntimeError, "would delete 1 of 2")

    result = run_migrator([legacy_list(500)])

    refute result[:success]
    assert_includes result[:error], "would delete 1 of 2"
    assert ::UserList.exists?(501)
  end

  test "the full migration deletes nothing" do
    result = run_migrator([legacy_list(500)], sync: nil)

    assert result[:success], result[:error]
    assert ::UserList.exists?(501)
    refute result[:data].key?(:deleted)
  end
end
