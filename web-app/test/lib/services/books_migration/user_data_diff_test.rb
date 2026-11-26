require "test_helper"

class Services::BooksMigration::UserDataDiffTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper
  include SequenceIsolation

  isolate_sequences "reviews", "corrections"

  setup do
    ::Review.delete_all
    @user = users(:regular_user)
    @editor = users(:editor_user)
    @t = Time.utc(2025, 1, 1)
  end

  # Not named `diff`: Minitest calls its own diff(expected, actual) to explain a
  # failed assert_equal.
  def user_data_diff(legacy, redirects: [], books_watermark: 200_000)
    Services::BooksMigration::UserDataDiff.call(
      scope: sync_scope(redirects: redirects, books_watermark: books_watermark), legacy: legacy
    )
  end

  test "counts users to insert and update, and those legacy deleted" do
    User.insert_all([
      {id: 5_001, email: "same@example.com", created_at: @t, updated_at: @t},
      {id: 5_002, email: "older@example.com", created_at: @t, updated_at: @t},
      {id: 5_003, email: "gone@example.com", created_at: @t, updated_at: @t}
    ])
    legacy = FakeLegacySource.new(user_versions: {5_001 => @t, 5_002 => @t + 1.day, 5_004 => @t})

    assert_equal({legacy: 3, here: 3, inserted: 1, updated: 1, deleted_on_legacy: 1}, user_data_diff(legacy)[:users])
  end

  test "counts saved searches and reading goals legacy deleted" do
    # Reading-goal fixtures use explicit ids below the 10,000 floor, so they would
    # count as legacy-origin.
    ::Books::ReadingGoal.delete_all
    ::Books::SavedSearch.create!(id: 15_001, user: @user, name: "Gone", criteria: {"genre_match_mode" => "any"})
    legacy = FakeLegacySource.new(saved_search_versions: {15_002 => @t}, reading_goal_ids: [1])

    result = user_data_diff(legacy)

    assert_equal({legacy: 1, here: 1, inserted: 1, updated: 0, deleted: 1, categories_removed: 0}, result[:saved_searches])
    assert_equal({legacy: 1, here: 0, deleted: 0}, result[:reading_goals])
  end

  test "counts the categories a sync would remove from saved searches" do
    genre = ::Books::Category.create!(name: "Kept Genre", category_type: :genre)
    LegacyIdMap.record(model: "Books::Category", legacy_id: 31, new_id: genre.id)
    LegacyIdMap.record(model: "Books::Category", legacy_id: 32, new_id: 999_999_999) # deleted here
    criteria = [
      {"included_category_ids" => ["31", "32"]}.to_json,
      {"excluded_category_ids" => [32], "genre_match_mode" => "any"}.to_json,
      {"genre_match_mode" => "any"}.to_json
    ]

    reported = user_data_diff(FakeLegacySource.new(saved_search_criteria: criteria))[:saved_searches][:categories_removed]

    rows = criteria.each_with_index.map do |raw, index|
      {"id" => 15_101 + index, "user_id" => @user.id, "name" => "S#{index}", "description" => nil, "criteria" => raw,
       "public" => false, "last_executed_at" => nil, "result_count" => nil, "created_at" => @t, "updated_at" => @t}
    end
    migrator = Services::BooksMigration::SavedSearchMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    Services::BooksMigration.stubs(:bump_sequence_to_floor!) # keep the saved_searches sequence where it is
    migrated = migrator.call

    assert_equal 2, reported
    assert_equal reported, migrated[:data][:categories_removed]
  end

  test "only lists whose items differ are planned item by item" do
    book = ::Books::Book.create!(title: "Listed")
    list = ::Books::UserList.create!(id: 900, user: @user, name: "Same", list_type: :custom)
    UserListItem.create!(user_list: list, listable: book, position: 1)
    same = {"id" => 1, "user_list_id" => 900, "book_id" => book.id, "position" => 1}
    legacy = FakeLegacySource.new(user_list_versions: {900 => @t}, user_list_items: [same])
    legacy.expects(:user_list_items_for).never

    counts = user_data_diff(legacy)[:user_list_items]

    assert_equal({legacy: 1, here: 1, inserted: 0, deleted: 0}, counts.slice(:legacy, :here, :inserted, :deleted))
  end

  test "counts list items and reviews whose book is neither here nor redirected as missing" do
    legacy = FakeLegacySource.new(
      user_list_versions: {901 => @t},
      user_list_items: [{"id" => 5, "user_list_id" => 901, "book_id" => 150_000, "position" => 1}],
      review_rows: [[300, @user.id, 150_000, @t]]
    )

    result = user_data_diff(legacy)

    assert_equal 1, result[:user_list_items][:missing]
    assert_equal 1, result[:reviews][:missing]
  end

  test "books the run itself brings over count as here" do
    legacy = FakeLegacySource.new(review_rows: [[301, @user.id, 200_500, @t]])

    result = Services::BooksMigration::UserDataDiff.call(
      scope: sync_scope(book_ids: [200_500], books_watermark: 200_500), legacy: legacy
    )

    assert_equal({inserted: 1, missing: 0, waiting: 0}, result[:reviews].slice(:inserted, :missing, :waiting))
  end

  test "its numbers equal what the following sync does" do
    init_watermarks(books: 200_000, authors: 100_000, book_identifiers: 0)
    plain = ::Books::Book.create!(id: 199_001, title: "Plain")
    survivor = ::Books::Book.create!(id: 199_002, title: "Survivor")
    other = ::Books::Book.create!(id: 199_005, title: "Removed From The List On Legacy")
    RecordRedirect.create!(item_type: "Books::Book", from_id: 199_003, to_id: survivor.id)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 199_004, to_id: nil)

    kept_list = ::Books::UserList.create!(id: 800, user: @user, name: "Kept", list_type: :custom)
    gone_list = ::Books::UserList.create!(id: 801, user: @user, name: "Gone", list_type: :custom)
    UserListItem.create!(user_list: kept_list, listable: plain, position: 1)
    UserListItem.create!(user_list: kept_list, listable: other, position: 2)
    UserListItem.create!(user_list: gone_list, listable: plain, position: 1)
    ::Review.create!(id: 900, user: @user, reviewable: plain, rating: 3)
    ::Review.create!(id: 250_900, user: @editor, reviewable: survivor, rating: 3)

    list_row = ->(id) {
      {"id" => id, "user_id" => @user.id, "name" => "L#{id}", "description" => nil, "list_type" => 4,
       "view_mode" => nil, "public" => true, "position" => 1, "created_at" => @t, "updated_at" => @t}
    }
    item = ->(id, list_id, book_id, position) {
      {"id" => id, "user_list_id" => list_id, "book_id" => book_id, "position" => position, "read_date" => nil,
       "created_at" => @t, "updated_at" => @t}
    }
    review = ->(id, user, book_id) {
      {"id" => id, "user_id" => user.id, "book_id" => book_id, "title" => nil, "body" => nil, "rating" => 4,
       "created_at" => @t, "updated_at" => @t}
    }
    changeset = ->(id, book_id) {
      {"id" => id, "changeable_type" => "Book", "changeable_id" => book_id, "user_id" => nil, "change_data" => {},
       "notes" => "n", "status" => 0, "applied_at" => nil, "created_at" => @t, "updated_at" => @t}
    }

    lists = [list_row.call(800), list_row.call(802)]
    items = [
      item.call(1, 800, plain.id, 1), item.call(2, 800, 199_003, 2), item.call(3, 800, survivor.id, 3),
      item.call(4, 802, 199_004, 1), item.call(5, 802, 200_050, 2), item.call(6, 802, plain.id, 3)
    ]
    reviews = [
      review.call(903, @user, 199_003), review.call(902, @user, survivor.id),
      review.call(901, @editor, survivor.id), review.call(899, @user, 200_050), review.call(898, @editor, 199_004)
    ]
    changesets = [changeset.call(9_501, plain.id), changeset.call(9_502, 199_004), changeset.call(9_503, 200_050)]

    legacy = FakeLegacySource.new(
      user_list_versions: lists.to_h { |row| [row["id"], row["updated_at"]] },
      user_list_items: items,
      review_rows: reviews.map { |row| row.values_at("id", "user_id", "book_id", "updated_at") },
      correction_rows: changesets.map { |row| row.values_at("id", "changeable_id") }
    )
    scope = Services::BooksMigration::SyncPlan.build(legacy: legacy).scope
    expected = Services::BooksMigration::UserDataDiff.call(scope: scope, legacy: legacy)

    run = ->(klass, rows) {
      migrator = klass.new(sync: scope)
      migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
      migrator.call
    }
    list_result = run.call(Services::BooksMigration::UserListMigrator, lists)
    items_migrator = Services::BooksMigration::UserListItemMigrator.new(sync: scope)
    items_migrator.define_singleton_method(:legacy_items_for) { |ids| items.select { |row| ids.include?(row["user_list_id"]) } }
    items_migrator.define_singleton_method(:legacy_item_count) { items.size }
    item_result = items_migrator.call
    review_result = run.call(Services::BooksMigration::ReviewMigrator, reviews)
    correction_result = run.call(Services::BooksMigration::CorrectionMigrator, changesets)

    item_keys = %i[inserted deleted dropped waiting collisions]
    review_keys = item_keys + [:held_by_new_app]
    correction_keys = %i[inserted dropped waiting missing]
    assert_equal({inserted: 1, deleted: 1}, expected[:user_lists].slice(:inserted, :deleted))
    assert_equal expected[:user_lists].slice(:inserted, :deleted), list_result[:data].slice(:inserted, :deleted)
    assert_equal({inserted: 2, deleted: 1, dropped: 1, waiting: 1, collisions: 1}, expected[:user_list_items].slice(*item_keys))
    assert_equal expected[:user_list_items].slice(*item_keys), item_result[:data].slice(*item_keys)
    assert_equal({inserted: 1, deleted: 1, dropped: 1, waiting: 1, collisions: 1, held_by_new_app: 1},
      expected[:reviews].slice(*review_keys))
    assert_equal expected[:reviews].slice(*review_keys), review_result[:data].slice(*review_keys)
    assert_equal({inserted: 1, dropped: 1, waiting: 1, missing: 0}, expected[:corrections].slice(*correction_keys))
    assert_equal expected[:corrections].slice(*correction_keys), correction_result[:data].slice(*correction_keys)
  end

  # The held counts must be what the sync reports on the same data, or a second report
  # after a sync never reaches 0. Held ids are the union of three routes: a row here whose
  # pair is held, a legacy row naming a held book, and a legacy row routed onto one.
  test "counts the re-import hold the way the migrators apply it" do
    init_watermarks(books: 200_000, authors: 100_000, book_identifiers: 0)
    plain = ::Books::Book.create!(id: 199_001, title: "Plain")
    fresh = ::Books::Book.create!(id: 199_002, title: "Fresh")
    held_book = ::Books::Book.create!(id: 199_010, title: "Held")
    moved_book = ::Books::Book.create!(id: 199_011, title: "Moved Here")
    RecordRedirect.create!(item_type: "Books::Book", from_id: 199_003, to_id: held_book.id)
    hold = Services::BooksMigration::ReimportHold.new(
      pairs: [[@user.id, held_book.id], [@user.id, moved_book.id]].to_set, redirects: Services::BooksMigration::Redirects.new([])
    )

    list = ::Books::UserList.create!(id: 800, user: @user, name: "Kept", list_type: :custom)
    UserListItem.create!(user_list: list, listable: plain, position: 1)
    UserListItem.create!(user_list: list, listable: held_book, position: 2)
    ::Review.create!(id: 900, user: @user, reviewable: held_book, rating: 3)
    ::Review.create!(id: 950, user: @user, reviewable: moved_book, rating: 3)

    item = ->(id, book_id, position) {
      {"id" => id, "user_list_id" => 800, "book_id" => book_id, "position" => position, "read_date" => nil,
       "created_at" => @t, "updated_at" => @t}
    }
    items = [item.call(1, plain.id, 1), item.call(2, held_book.id, 2), item.call(3, fresh.id, 3)]
    review = ->(id, book_id) {
      {"id" => id, "user_id" => @user.id, "book_id" => book_id, "title" => nil, "body" => nil, "rating" => 4,
       "created_at" => @t, "updated_at" => @t}
    }
    # 950 sits here only, on a held pair legacy no longer has. 903 is free; 902 reaches the held book through a redirect; 900 is held by its id and its book.
    reviews = [review.call(903, plain.id), review.call(902, 199_003), review.call(900, held_book.id)]
    legacy = FakeLegacySource.new(
      user_list_versions: {800 => @t}, user_list_items: items,
      review_rows: reviews.map { |row| row.values_at("id", "user_id", "book_id", "updated_at") }
    )
    scope = Services::BooksMigration::SyncPlan.build(legacy: legacy).scope
    scope.hold = hold

    expected = Services::BooksMigration::UserDataDiff.call(scope: scope, legacy: legacy)

    items_migrator = Services::BooksMigration::UserListItemMigrator.new(sync: scope)
    items_migrator.define_singleton_method(:legacy_items_for) { |ids| items.select { |row| ids.include?(row["user_list_id"]) } }
    items_migrator.define_singleton_method(:legacy_item_count) { items.size }
    item_result = items_migrator.call
    review_migrator = Services::BooksMigration::ReviewMigrator.new(sync: scope)
    review_migrator.stubs(:legacy_each).multiple_yields(*reviews.zip)
    review_result = review_migrator.call

    assert_equal({inserted: 1, deleted: 0, held_legacy: 1, held_here: 1}, expected[:user_list_items].slice(:inserted, :deleted, :held_legacy, :held_here))
    assert_equal expected[:user_list_items].slice(:inserted, :deleted, :held_legacy, :held_here),
      item_result[:data].slice(:inserted, :deleted, :held_legacy, :held_here)
    # updated is asserted literally: the migrator does not track it.
    assert_equal({inserted: 1, deleted: 0, updated: 0, held: 3}, expected[:reviews].slice(:inserted, :deleted, :updated, :held))
    assert_equal expected[:reviews].slice(:inserted, :deleted, :held), review_result[:data].slice(:inserted, :deleted, :held)
  end

  test "a hold with no list_users would hold nothing, so the diff must pass them" do
    plain = ::Books::Book.create!(id: 199_001, title: "Plain")
    list = ::Books::UserList.create!(id: 800, user: @user, name: "Kept", list_type: :custom)
    UserListItem.create!(user_list: list, listable: plain, position: 1)
    hold = Services::BooksMigration::ReimportHold.new(
      pairs: [[@user.id, plain.id]].to_set, redirects: Services::BooksMigration::Redirects.new([])
    )
    row = {"id" => 1, "user_list_id" => 800, "book_id" => 199_002, "position" => 1, "read_date" => nil, "created_at" => @t, "updated_at" => @t}
    ::Books::Book.create!(id: 199_002, title: "Other")
    legacy = FakeLegacySource.new(user_list_versions: {800 => @t}, user_list_items: [row])

    result = Services::BooksMigration::UserDataDiff.call(scope: sync_scope(hold: hold), legacy: legacy)

    assert_equal [1, 0, 1], result[:user_list_items].values_at(:inserted, :deleted, :held_here)
  end

  test "a list that exists only on legacy holds its item on a held pair" do
    plain = ::Books::Book.create!(id: 199_001, title: "Plain")
    hold = Services::BooksMigration::ReimportHold.new(
      pairs: [[@user.id, plain.id]].to_set, redirects: Services::BooksMigration::Redirects.new([])
    )
    row = {"id" => 1, "user_list_id" => 805, "book_id" => plain.id, "position" => 1, "read_date" => nil, "created_at" => @t, "updated_at" => @t}
    legacy = FakeLegacySource.new(
      user_list_versions: {805 => @t}, user_list_items: [row], user_list_owners: {805 => @user.id}
    )

    result = Services::BooksMigration::UserDataDiff.call(scope: sync_scope(hold: hold), legacy: legacy)

    assert_equal [0, 1], result[:user_list_items].values_at(:inserted, :held_legacy)
  end
end
