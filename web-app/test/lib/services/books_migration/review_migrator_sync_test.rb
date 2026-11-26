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
  def run_sync(rows, redirects: [], books_watermark: Float::INFINITY, sync: :default, hold: Services::BooksMigration::ReimportHold.none)
    scope = (sync == :default) ? sync_scope(redirects: redirects, books_watermark: books_watermark, hold: hold) : sync
    migrator = Services::BooksMigration::ReviewMigrator.new(sync: scope)
    stub = migrator.stubs(:legacy_each)
    stub.multiple_yields(*rows.zip) if rows.any?
    migrator.call
  end

  def here_review(id, book: @book, user: @user, rating: 2)
    ::Review.create!(id: id, user: user, reviewable: book, rating: rating)
  end

  def stats(result) = result[:data].slice(:inserted, :deleted, :dropped, :waiting, :collisions, :held_by_new_app)

  def hold_for(*pairs) = Services::BooksMigration::ReimportHold.new(pairs: pairs.to_set, redirects: Services::BooksMigration::Redirects.new([]))

  test "leaves a moved review's id on its new book" do
    here_review(100, book: @survivor, rating: 3.75)

    result = run_sync([legacy_review(100, "book_id" => @book.id, "rating" => 3)],
      hold: hold_for([@user.id, @book.id], [@user.id, @survivor.id]))

    assert result[:success], result[:error]
    review = ::Review.find(100)
    assert_equal [@survivor.id, 3.75], [review.reviewable_id, review.rating.to_f]
    assert_equal 0, result[:data][:deleted]
    assert_equal 1, result[:data][:held]
  end

  test "keeps a re-import review legacy lacks" do
    here_review(101, book: @survivor)

    result = run_sync([], hold: hold_for([@user.id, @survivor.id]))

    assert result[:success], result[:error]
    assert ::Review.exists?(101)
    assert_equal 0, result[:data][:deleted]
    assert_equal 1, result[:data][:held]
  end

  test "an unheld review of the same reader still syncs" do
    result = run_sync([legacy_review(102, "book_id" => @book.id, "rating" => 5)],
      hold: hold_for([@user.id, @survivor.id]))

    assert result[:success], result[:error]
    review = ::Review.find(102)
    assert_equal [@book.id, 5], [review.reviewable_id, review.rating.to_f]
    assert_equal 0, result[:data][:held]
  end

  test "a legacy row naming a held review's id cannot move it" do
    other = ::Books::Book.create!(title: "Legacy merge target")
    here_review(103, book: @survivor, rating: 3.75)

    result = run_sync([legacy_review(103, "book_id" => other.id, "rating" => 3)], hold: hold_for([@user.id, @survivor.id]))

    assert result[:success], result[:error]
    review = ::Review.find(103)
    assert_equal [@survivor.id, 3.75], [review.reviewable_id, review.rating.to_f]
    assert_equal [0, 1], [result[:data][:deleted], result[:data][:held]]
  end

  test "a row held only through its routed book is not written" do
    result = run_sync([legacy_review(104, "book_id" => 200_001)],
      redirects: [["Books::Book", 200_001, @survivor.id]], hold: hold_for([@user.id, @survivor.id]))

    assert result[:success], result[:error]
    refute ::Review.exists?(104)
    assert_equal 1, result[:data][:held]
  end

  test "a row held only on its legacy book is not written onto the redirect target" do
    result = run_sync([legacy_review(105, "book_id" => 200_002)],
      redirects: [["Books::Book", 200_002, @survivor.id]], hold: hold_for([@user.id, 200_002]))

    assert result[:success], result[:error]
    refute ::Review.exists?(105)
    assert_equal [1, 0], result[:data].values_at(:held, :dropped)
  end

  test "a held row on a deleted legacy book counts as held, not dropped" do
    result = run_sync([legacy_review(106, "book_id" => 200_003)],
      redirects: [["Books::Book", 200_003, nil]], hold: hold_for([@user.id, 200_003]))

    assert result[:success], result[:error]
    assert_equal [1, 0], result[:data].values_at(:held, :dropped)
  end

  test "a row rerouted onto a held pair is skipped" do
    stale = Services::BooksMigration::BookRoute.new(sync_scope, book_ids_here: Set[200_001, @survivor.id])
    Services::BooksMigration::BookRoute.stubs(:new).returns(stale)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 200_001, to_id: @survivor.id)

    result = run_sync([legacy_review(131, "book_id" => 200_001, "rating" => 5)],
      redirects: [], hold: hold_for([@user.id, @survivor.id]))

    assert result[:success], result[:error]
    refute ::Review.exists?(131)
    assert_equal 1, result[:data][:held]
  end

  test "a held review whose book is merged after the run read its redirects is kept" do
    # The re-import put review 140 on dest; legacy never had it. Dest was merged into @survivor after
    # SyncPlan built the hold, before the reviews step.
    dest = ::Books::Book.create!(title: "Re-import destination")
    redirects = Services::BooksMigration::Redirects.load
    hold = Services::BooksMigration::ReimportHold.new(pairs: [[@user.id, dest.id]], redirects: redirects)
    here_review(140, book: @survivor)
    RecordRedirect.create!(item_type: "Books::Book", from_id: dest.id, to_id: @survivor.id)
    dest.delete

    result = run_sync([], sync: sync_scope(redirects: redirects, hold: hold))

    assert result[:success], result[:error]
    assert ::Review.exists?(140)
    assert_equal [0, 1], result[:data].values_at(:deleted, :held)
  end

  test "a legacy row written onto a pair a mid-run merge made held does not displace the re-import's review" do
    # Review 141 (the re-import's) sits on dest, a held pair. Legacy also has the reader's review 142 on
    # @survivor. Dest is merged into @survivor while the step runs, after the reviews here were read:
    # (reader, @survivor) is now held, so legacy's row must not be written over the re-import's review.
    dest = ::Books::Book.create!(title: "Re-import destination")
    redirects = Services::BooksMigration::Redirects.load
    hold = Services::BooksMigration::ReimportHold.new(pairs: [[@user.id, dest.id]], redirects: redirects)
    here_review(141, book: dest, rating: 3.75)
    migrator = Services::BooksMigration::ReviewMigrator.new(sync: sync_scope(redirects: redirects, hold: hold))
    row = legacy_review(142, "book_id" => @survivor.id, "rating" => 1)
    merge = lambda do
      ::Review.where(id: 141).update_all(reviewable_id: @survivor.id)
      RecordRedirect.create!(item_type: "Books::Book", from_id: dest.id, to_id: @survivor.id)
      dest.delete
    end
    migrator.define_singleton_method(:legacy_each) do |&block|
      merge.call
      block.call(row)
    end

    result = migrator.call

    assert result[:success], result[:error]
    review = ::Review.find(141)
    assert_equal [@survivor.id, 3.75], [review.reviewable_id, review.rating.to_f]
    refute ::Review.exists?(142)
  end

  test "a review a mid-run merge moves onto a held pair is not deleted" do
    # Review 143 sits on an unheld book when the step starts, and legacy lacks it. A merge while the step runs
    # moves it onto (reader, dest), a held pair: it is now the reader's review there, and is kept.
    dest = ::Books::Book.create!(title: "Re-import destination")
    other = ::Books::Book.create!(title: "Merged into dest")
    redirects = Services::BooksMigration::Redirects.load
    hold = Services::BooksMigration::ReimportHold.new(pairs: [[@user.id, dest.id]], redirects: redirects)
    here_review(143, book: other)
    migrator = Services::BooksMigration::ReviewMigrator.new(sync: sync_scope(redirects: redirects, hold: hold))
    migrator.define_singleton_method(:legacy_each) do |&_block|
      ::Review.where(id: 143).update_all(reviewable_id: dest.id)
      RecordRedirect.create!(item_type: "Books::Book", from_id: other.id, to_id: dest.id)
      other.delete
    end

    result = migrator.call

    assert result[:success], result[:error]
    assert ::Review.exists?(143)
    assert_equal [0, 1], result[:data].values_at(:deleted, :held)
  end

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
