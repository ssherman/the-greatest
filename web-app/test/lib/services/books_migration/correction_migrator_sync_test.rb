require "test_helper"

class Services::BooksMigration::CorrectionMigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper
  include SequenceIsolation

  isolate_sequences "corrections"

  setup do
    @survivor = ::Books::Book.create!(title: "Survivor")
  end

  def legacy_changeset(id, book_id)
    {
      "id" => id, "changeable_type" => "Book", "changeable_id" => book_id, "user_id" => nil, "change_data" => {},
      "notes" => "Fix it", "status" => 0, "applied_at" => nil,
      "created_at" => Time.utc(2025, 1, 2), "updated_at" => Time.utc(2025, 1, 2)
    }
  end

  def run_sync(rows, redirects: [], books_watermark: Float::INFINITY)
    migrator = Services::BooksMigration::CorrectionMigrator.new(sync: sync_scope(redirects: redirects, books_watermark: books_watermark))
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "puts a correction on a merged book's survivor" do
    result = run_sync([legacy_changeset(9_001, 200_001)], redirects: [["Books::Book", 200_001, @survivor.id]])

    assert result[:success], result[:error]
    assert_equal @survivor.id, ::Correction.find(9_001).correctable_id
    assert_equal 1, result[:data][:inserted]
  end

  test "drops a correction on a deleted book, and waits on one whose book has not arrived" do
    result = run_sync([legacy_changeset(9_002, 200_002), legacy_changeset(9_003, 200_003)],
      redirects: [["Books::Book", 200_002, nil]], books_watermark: 200_000)

    assert result[:success], result[:error]
    refute ::Correction.exists?(9_002)
    refute ::Correction.exists?(9_003)
    assert_equal [1, 1], result[:data].values_at(:dropped, :waiting)
  end

  test "a waiting correction lands once its book arrives" do
    ::Books::Book.create!(id: 200_003, title: "Arrived")

    run_sync([legacy_changeset(9_003, 200_003)], books_watermark: 200_005)

    assert_equal 200_003, ::Correction.find(9_003).correctable_id
  end

  test "skips a correction whose book is neither here nor redirected, as the full migration does" do
    result = run_sync([legacy_changeset(9_004, 150_000)], books_watermark: 200_000)

    assert result[:success], result[:error]
    refute ::Correction.exists?(9_004)
    assert_equal 1, result[:data][:missing]
  end

  test "a book merged after the run started is noticed, and the correction lands on the survivor" do
    # Built before the merge: still thinks 200_001 is here, knows no redirect.
    stale = Services::BooksMigration::BookRoute.new(sync_scope, book_ids_here: Set[200_001, @survivor.id])
    Services::BooksMigration::BookRoute.stubs(:new).returns(stale)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 200_001, to_id: @survivor.id)

    result = run_sync([legacy_changeset(9_006, 200_001)])

    assert result[:success], result[:error]
    assert_equal @survivor.id, ::Correction.find(9_006).correctable_id
  end

  test "counts only what it inserts" do
    run_sync([legacy_changeset(9_005, @survivor.id)])

    result = run_sync([legacy_changeset(9_005, @survivor.id)])

    assert_equal 0, result[:data][:inserted]
  end
end
