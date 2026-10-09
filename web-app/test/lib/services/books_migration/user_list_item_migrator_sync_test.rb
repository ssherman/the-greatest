require "test_helper"

class Services::BooksMigration::UserListItemMigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  setup do
    @user = users(:regular_user)
    @list = ::Books::UserList.create!(id: 600, user: @user, name: "Legacy List", list_type: :custom)
    @book = ::Books::Book.create!(title: "Plain")
    @survivor = ::Books::Book.create!(title: "Survivor")
  end

  def legacy_item(id, book_id, position, list_id: @list.id, read_date: nil)
    {
      "id" => id, "user_list_id" => list_id, "book_id" => book_id, "position" => position, "read_date" => read_date,
      "created_at" => Time.utc(2025, 1, 1), "updated_at" => Time.utc(2025, 1, 2)
    }
  end

  def run_sync(rows, redirects: [], books_watermark: Float::INFINITY)
    migrator = Services::BooksMigration::UserListItemMigrator.new(
      sync: sync_scope(redirects: redirects, books_watermark: books_watermark)
    )
    migrator.define_singleton_method(:legacy_items_for) do |list_ids|
      rows.select { |row| list_ids.include?(row["user_list_id"]) }
    end
    migrator.call
  end

  def listed(list = @list) = UserListItem.where(user_list_id: list.id).order(:position).pluck(:listable_id)

  def add_here(list, book, position)
    UserListItem.insert_all([{
      user_list_id: list.id, listable_type: "Books::Book", listable_id: book.id, position: position,
      created_at: Time.current, updated_at: Time.current
    }])
  end

  test "routes an item on a merged book onto the survivor" do
    result = run_sync([legacy_item(1, 200_001, 1)], redirects: [["Books::Book", 200_001, @survivor.id]])

    assert result[:success], result[:error]
    assert_equal [@survivor.id], listed
    assert_equal 1, result[:data][:inserted]
  end

  test "a merge that leaves two items for one book keeps the one at the lower position" do
    result = run_sync(
      [legacy_item(2, 200_001, 1), legacy_item(3, @book.id, 3), legacy_item(4, @survivor.id, 5)],
      redirects: [["Books::Book", 200_001, @survivor.id]]
    )

    assert result[:success], result[:error]
    assert_equal [@survivor.id, @book.id], listed
    assert_equal 1, result[:data][:collisions]
  end

  test "drops an item whose book was deleted and counts it" do
    result = run_sync([legacy_item(1, 200_002, 1)], redirects: [["Books::Book", 200_002, nil]])

    assert result[:success], result[:error]
    assert_empty listed
    assert_equal 1, result[:data][:dropped]
  end

  test "skips an item on a book the run has not copied yet, and counts it" do
    result = run_sync([legacy_item(1, @book.id, 1), legacy_item(2, 200_003, 2), legacy_item(3, @survivor.id, 3)],
      books_watermark: 200_000)

    assert result[:success], result[:error]
    assert_equal [@book.id, @survivor.id], listed
    assert_equal [1, 2], UserListItem.where(user_list_id: @list.id).order(:position).pluck(:position)
    assert_equal 1, result[:data][:waiting]
  end

  test "fails naming the legacy row when the book is neither here nor redirected" do
    result = run_sync([legacy_item(77, 150_000, 1)], books_watermark: 200_000)

    refute result[:success]
    assert_includes result[:error], "77"
  end

  test "a book merged after the run started is noticed, and its item lands on the survivor" do
    # The route was built before the merge: it still thinks 200_001 is here, and
    # knows no redirect. The merge has since committed.
    stale = Services::BooksMigration::BookRoute.new(sync_scope, book_ids_here: Set[200_001, @survivor.id])
    Services::BooksMigration::BookRoute.stubs(:new).returns(stale)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 200_001, to_id: @survivor.id)

    result = run_sync([legacy_item(1, 200_001, 1)])

    assert result[:success], result[:error]
    assert_equal [@survivor.id], listed
  end

  test "deletes an item legacy no longer has from a legacy-origin list" do
    add_here(@list, @book, 1)

    result = run_sync([legacy_item(1, @survivor.id, 1)])

    assert_equal [@survivor.id], listed
    assert_equal({inserted: 1, deleted: 1}, result[:data].slice(:inserted, :deleted))
  end

  test "an item already here takes legacy's values and is not counted as inserted" do
    add_here(@list, @book, 1)

    result = run_sync([legacy_item(1, @book.id, 1, read_date: Date.new(2024, 5, 1))])

    assert_equal Date.new(2024, 5, 1), UserListItem.find_by(user_list_id: @list.id, listable_id: @book.id).completed_on
    assert_equal 0, result[:data][:inserted]
  end

  test "leaves a new-app list's items and positions alone" do
    new_app = ::Books::UserList.create!(id: 1_000_600, user: @user, name: "New App", list_type: :custom)
    add_here(new_app, @book, 5)
    add_here(new_app, @survivor, 9)

    result = run_sync([legacy_item(1, @book.id, 4)])

    assert result[:success], result[:error]
    assert_equal [5, 9], UserListItem.where(user_list_id: new_app.id).order(:position).pluck(:position)
    assert_equal [1], UserListItem.where(user_list_id: @list.id).pluck(:position)
  end
end
