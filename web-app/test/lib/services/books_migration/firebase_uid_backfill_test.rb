require "test_helper"

class Services::BooksMigration::FirebaseUidBackfillTest < ActiveSupport::TestCase
  def run_backfill(ids, dry_run: false)
    backfill = Services::BooksMigration::FirebaseUidBackfill.new(dry_run: dry_run)
    backfill.stubs(:cohort_ids).returns(ids)
    backfill.call
  end

  def make_user(id, attrs = {})
    User.create!({id: id, email: "u#{id}@example.com"}.merge(attrs))
  end

  test "writes the derived uid onto every eligible user" do
    make_user(910001)
    make_user(910002)

    result = run_backfill([910001, 910002])

    assert result[:success], result[:error]
    assert_equal 2, result[:data][:updated]
    assert_equal "tgbv1-910001", User.find(910001).auth_uid
    assert_equal "tgbv1-910002", User.find(910002).auth_uid
  end

  # The backfill derives the uid in SQL ("tgbv1-" || id::text) so 30k rows do
  # not become 30k UPDATEs, while FirebasePasswordExport.uid_for owns the shape
  # in Ruby. Those are two implementations of one rule, and the plan's whole
  # argument for safety is that they cannot drift. This is the only thing
  # holding that, so it checks a spread of ids rather than one: a change to
  # uid_for's shape (zero-padding, a different separator, a suffix) has to fail
  # here.
  test "derives exactly the same uid the exporter does, across id shapes" do
    ids = [910003, 7, 42, 999_999_999]
    ids.each { |id| make_user(id) }

    run_backfill(ids)

    ids.each do |id|
      assert_equal Services::BooksMigration::FirebasePasswordExport.uid_for(id),
        User.find(id).auth_uid,
        "the SQL-derived uid diverged from FirebasePasswordExport.uid_for(#{id})"
    end
  end

  test "never overwrites an auth_uid that is already set" do
    make_user(910004, auth_uid: "firebase-native-uid")

    result = run_backfill([910004])

    assert_equal 0, result[:data][:updated]
    assert_equal 1, result[:data][:already_set]
    assert_equal "firebase-native-uid", User.find(910004).auth_uid
  end

  test "is idempotent -- a second run updates nothing" do
    make_user(910005)

    run_backfill([910005])
    second = run_backfill([910005])

    assert_equal 0, second[:data][:updated]
    assert_equal "tgbv1-910005", User.find(910005).auth_uid
  end

  # The id-preservation invariant. UserMigrator upserts unique_by: :id, so a
  # cohort id with no matching new-table row means the user migration did not
  # run or did not run fully. Backfilling around that would silently leave
  # those users unable to sign in.
  test "fails hard when a cohort id has no row in the new users table" do
    make_user(910006)

    result = run_backfill([910006, 99999999])

    refute result[:success]
    assert_includes result[:error], "99999999"
    assert_equal [99999999], result[:data][:missing_target]
  end

  test "a failed run writes nothing at all" do
    make_user(910007)

    run_backfill([910007, 99999999])

    assert_nil User.find(910007).auth_uid
  end

  test "dry_run reports what it would do and changes nothing" do
    make_user(910008)

    result = run_backfill([910008], dry_run: true)

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:eligible]
    assert_equal 0, result[:data][:updated]
    assert_nil User.find(910008).auth_uid
  end

  # dry_run has to report the real split, not just refuse to write -- it is the
  # only preview an operator gets before touching 30k production rows, and the
  # plan's Step 7 reads these exact numbers to decide whether to proceed.
  test "dry_run counts eligible and already_set separately" do
    make_user(910009)
    make_user(910010, auth_uid: "already-linked")

    result = run_backfill([910009, 910010], dry_run: true)

    assert_equal [1, 1, 0], [result[:data][:eligible], result[:data][:already_set], result[:data][:updated]]
    assert_nil User.find(910009).auth_uid
  end

  # The window the UPDATE's `auth_uid: nil` scope exists to close: a cohort
  # member signs in between the eligibility read and the write, Firebase issues
  # them a native uid, and the backfill must not overwrite it with tgbv1-<id>
  # and detach them from the account they just authenticated to.
  #
  # Stubbing eligible_ids is the only way to reach this -- through the ordinary
  # path every id has already been filtered, so dropping the scope from the
  # UPDATE passes every other test in this file. The assertion is on the public
  # outcome, not on the stubbed method.
  test "does not clobber a uid set between the eligibility check and the write" do
    make_user(910011, auth_uid: "issued-mid-run")

    backfill = Services::BooksMigration::FirebaseUidBackfill.new
    backfill.stubs(:cohort_ids).returns([910011])
    backfill.stubs(:eligible_ids).returns([910011])

    result = backfill.call

    assert result[:success], result[:error]
    assert_equal 0, result[:data][:updated], "a row that gained a uid mid-run must not be counted as updated"
    assert_equal "issued-mid-run", User.find(910011).auth_uid
  end

  test "reports success and touches nothing when the cohort is empty" do
    result = run_backfill([])

    assert result[:success], result[:error]
    assert_equal [0, 0, 0], [result[:data][:eligible], result[:data][:updated], result[:data][:already_set]]
    assert_empty result[:data][:missing_target]
  end
end
