require "test_helper"

class Services::BooksMigration::ReviewMigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper
  include SequenceIsolation

  isolate_sequences "reviews"

  setup do
    ::Review.delete_all
    ::ReviewSummary.delete_all
    @user = users(:regular_user)
    @other_user = users(:editor_user)
    @book = ::Books::Book.create!(title: "Reviewed")
    @survivor = ::Books::Book.create!(title: "Survivor")
  end

  def legacy_review(id, overrides = {})
    {
      "id" => id, "user_id" => @user.id, "book_id" => @book.id, "title" => nil, "body" => nil, "rating" => 4,
      "created_at" => Time.utc(2025, 1, 2), "updated_at" => Time.utc(2025, 6, 7)
    }.merge(overrides)
  end

  # Rows newest first, as the real legacy_each yields them.
  def run_sync(rows, redirects: [], books_watermark: Float::INFINITY, sync: :default)
    scope = (sync == :default) ? sync_scope(redirects: redirects, books_watermark: books_watermark) : sync
    migrator = Services::BooksMigration::ReviewMigrator.new(sync: scope)
    stub = migrator.stubs(:legacy_each)
    stub.multiple_yields(*rows.zip) if rows.any?
    migrator.call
  end

  def here_review(id, book: @book, user: @user, rating: 2)
    ::Review.create!(id: id, user: user, reviewable: book, rating: rating)
  end

  def stats(result) = result[:data].slice(:inserted, :deleted, :dropped, :waiting, :collisions, :held_by_new_app)

  test "overwrites a review legacy edited" do
    here_review(100, rating: 2)

    result = run_sync([legacy_review(100, "rating" => 5)])

    assert result[:success], result[:error]
    assert_equal 5, ::Review.find(100).rating
    assert_equal 0, result[:data][:inserted]
  end

  test "routes a review of a merged book onto the survivor" do
    run_sync([legacy_review(101, "book_id" => 200_001)], redirects: [["Books::Book", 200_001, @survivor.id]])

    assert_equal @survivor.id, ::Review.find(101).reviewable_id
  end

  test "a merge that gives one user two reviews of a book keeps the newer" do
    here_review(102, book: @survivor, rating: 1)

    result = run_sync(
      [legacy_review(103, "book_id" => 200_001, "rating" => 5), legacy_review(102, "book_id" => @survivor.id, "rating" => 1)],
      redirects: [["Books::Book", 200_001, @survivor.id]]
    )

    assert result[:success], result[:error]
    assert_equal 5, ::Review.find(103).rating
    refute ::Review.exists?(102)
    assert_equal({inserted: 1, deleted: 1, dropped: 0, waiting: 0, collisions: 1, held_by_new_app: 0}, stats(result))
  end

  test "drops a review of a deleted book and skips one whose book has not arrived" do
    result = run_sync(
      [legacy_review(105, "book_id" => 200_003), legacy_review(104, "book_id" => 200_002)],
      redirects: [["Books::Book", 200_002, nil]], books_watermark: 200_000
    )

    assert result[:success], result[:error]
    assert_equal 0, ::Review.count
    assert_equal [1, 1], result[:data].values_at(:dropped, :waiting)
  end

  test "fails naming the legacy row when the book is neither here nor redirected" do
    result = run_sync([legacy_review(106, "book_id" => 150_000)], books_watermark: 200_000)

    refute result[:success]
    assert_includes result[:error], "106"
  end

  test "a book merged after the run started is noticed, and its review lands on the survivor" do
    # Built before the merge: still thinks 200_001 is here, knows no redirect.
    stale = Services::BooksMigration::BookRoute.new(sync_scope, book_ids_here: Set[200_001, @survivor.id])
    Services::BooksMigration::BookRoute.stubs(:new).returns(stale)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 200_001, to_id: @survivor.id)

    result = run_sync([legacy_review(111, "book_id" => 200_001)])

    assert result[:success], result[:error]
    assert_equal @survivor.id, ::Review.find(111).reviewable_id
  end

  test "a mid-run merge that reroutes an older review onto a pair an earlier batch wrote keeps the newer" do
    # Built before the merge: still thinks 200_001 is here, knows no redirect.
    stale = Services::BooksMigration::BookRoute.new(sync_scope, book_ids_here: Set[200_001, @survivor.id])
    Services::BooksMigration::BookRoute.stubs(:new).returns(stale)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 200_001, to_id: @survivor.id)
    migrator = Services::BooksMigration::ReviewMigrator.new(sync: sync_scope)
    migrator.stubs(:upsert_batch).returns(1) # one review per batch
    migrator.stubs(:legacy_each).multiple_yields(
      [legacy_review(121, "book_id" => @survivor.id, "rating" => 5)],
      [legacy_review(120, "book_id" => 200_001, "rating" => 1)]
    )

    result = migrator.call

    assert result[:success], result[:error]
    assert_equal 5, ::Review.find(121).rating
    refute ::Review.exists?(120)
    assert_equal 1, result[:data][:collisions]
  end

  test "deletes a legacy-origin books review legacy no longer has, and leaves new-app reviews alone" do
    here_review(107)
    new_app = here_review(250_001, book: @survivor)

    result = run_sync([])

    assert result[:success], result[:error]
    refute ::Review.exists?(107)
    assert ::Review.exists?(new_app.id)
    assert_equal 1, result[:data][:deleted]
  end

  test "a new-app review of the same book by the same user wins over the legacy one" do
    here_review(250_002)

    result = run_sync([legacy_review(108)])

    assert result[:success], result[:error]
    refute ::Review.exists?(108)
    assert ::Review.exists?(250_002)
    assert_equal 1, result[:data][:held_by_new_app]
  end

  test "refuses past the deletion guard and deletes nothing" do
    here_review(109)
    Services::BooksMigration.expects(:guard_deletion!).with("reviews", 1, 1).raises(RuntimeError, "would delete 1 of 1")

    result = run_sync([])

    refute result[:success]
    assert ::Review.exists?(109)
  end

  test "the full migration stays insert-only" do
    here_review(110, rating: 2)

    result = run_sync([legacy_review(110, "rating" => 5)], sync: nil)

    assert result[:success], result[:error]
    assert_equal 2, ::Review.find(110).rating
  end
end
