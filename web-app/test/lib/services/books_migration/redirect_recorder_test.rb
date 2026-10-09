require "test_helper"

class Services::BooksMigration::RedirectRecorderTest < ActiveSupport::TestCase
  Recorder = Services::BooksMigration::RedirectRecorder

  def fate(item_type, from_id)
    RecordRedirect.find_by(item_type: item_type, from_id: from_id)
  end

  test "records a legacy-origin merge" do
    Recorder.merged(item_type: "Books::Book", from_id: 1_001, to_id: 2_002)

    assert_equal 2_002, fate("Books::Book", 1_001).to_id
  end

  test "records a legacy-origin delete with no survivor" do
    Recorder.deleted(item_type: "Books::Author", from_id: 1_001)

    row = fate("Books::Author", 1_001)
    assert row
    assert_nil row.to_id
  end

  test "records nothing for an id at or above the ceiling" do
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books")

    Recorder.merged(item_type: "Books::Book", from_id: ceiling, to_id: 7)
    Recorder.deleted(item_type: "Books::Book", from_id: ceiling + 1)

    assert_equal 0, RecordRedirect.count
  end

  test "uses each item type's own ceiling" do
    author_ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_authors")

    Recorder.deleted(item_type: "Books::Book", from_id: author_ceiling)
    Recorder.deleted(item_type: "Books::Author", from_id: author_ceiling)

    assert fate("Books::Book", author_ceiling)
    assert_nil fate("Books::Author", author_ceiling)
  end

  test "a delete after a merge keeps the merge" do
    Recorder.merged(item_type: "Books::Book", from_id: 1_001, to_id: 2_002)
    Recorder.deleted(item_type: "Books::Book", from_id: 1_001)

    assert_equal 2_002, fate("Books::Book", 1_001).to_id
  end

  test "a merge overwrites an earlier delete" do
    Recorder.deleted(item_type: "Books::Book", from_id: 1_001)
    Recorder.merged(item_type: "Books::Book", from_id: 1_001, to_id: 2_002)

    assert_equal 2_002, fate("Books::Book", 1_001).to_id
  end

  test "repoints rows that named a record merged away, even a new-app one" do
    new_app_id = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books") + 5
    Recorder.merged(item_type: "Books::Book", from_id: 1_001, to_id: new_app_id)

    Recorder.merged(item_type: "Books::Book", from_id: new_app_id, to_id: 3_003)

    assert_equal 3_003, fate("Books::Book", 1_001).to_id
    assert_nil fate("Books::Book", new_app_id)
  end

  test "repoints rows that named a deleted record to deleted" do
    new_app_id = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books") + 5
    Recorder.merged(item_type: "Books::Book", from_id: 1_001, to_id: new_app_id)

    Recorder.deleted(item_type: "Books::Book", from_id: new_app_id)

    assert_nil fate("Books::Book", 1_001).to_id
  end

  # A was merged into B, the weekly :all brought A back, then B was merged into A:
  # the repoint would leave A -> A, and resolving A would raise a cycle forever.
  test "a merge into a record that had been merged away drops the self-loop" do
    Recorder.merged(item_type: "Books::Book", from_id: 1_001, to_id: 2_002)

    Recorder.merged(item_type: "Books::Book", from_id: 2_002, to_id: 1_001)

    assert_nil fate("Books::Book", 1_001)
    assert_equal 1_001, fate("Books::Book", 2_002).to_id
  end

  test "repoints within the item type only" do
    Recorder.merged(item_type: "Books::Author", from_id: 1_001, to_id: 2_002)

    Recorder.deleted(item_type: "Books::Book", from_id: 2_002)

    assert_equal 2_002, fate("Books::Author", 1_001).to_id
  end
end
