require "test_helper"
require "rake"

class PenaltiesRakeTest < ActiveSupport::TestCase
  setup do
    # Deliberately not `Rails.application.load_tasks`: it walks every
    # railtie's rake_tasks hook, and some (see user_favorites_rake_test.rb)
    # get registered more than once per process, so reloading them a second
    # time in an already-booted process re-`load`s their files and Ruby warns
    # "already initialized constant ...". Loading only the one file this test
    # needs avoids most of that noise.
    #
    # One source remains outside our control: a whole-suite `bin/rails test`
    # run has Rails itself `load` every `.rake` file once while booting,
    # before parallel test workers fork -- so `ENTRIES` already exists in
    # every worker. Rake's own task registry does not survive that fork the
    # same way, so `task_defined?` below is legitimately false in a worker
    # even though the constant is already set, and the `load` needed to
    # register the task re-assigns `ENTRIES` to the identical value. That
    # redefinition is expected, not a bug, so it's the one `load` in this
    # file silenced rather than fixed at the cause.
    unless Rake::Task.task_defined?("penalties:backfill")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/penalties.rake").to_s }
    end
    @task = Rake::Task["penalties:backfill"]
    @task.reenable
  end

  test "assigns a category and description to a penalty it knows when the name matches" do
    penalty = Penalty.create!(id: 990_001, type: "Global::Penalty", name: "Placeholder")
    Penalties::Backfill::ENTRIES[990_001] = {
      name: "Placeholder",
      category: :list_integrity,
      description: "A test description."
    }

    result = Penalties::Backfill.call

    penalty.reload
    assert_equal "list_integrity", penalty.category
    assert_equal "A test description.", penalty.description
    assert_equal 1, result[:updated]
    assert_empty result[:mismatched]
  ensure
    Penalties::Backfill::ENTRIES.delete(990_001)
  end

  test "is idempotent - a second run changes nothing" do
    penalty = Penalty.create!(id: 990_002, type: "Global::Penalty", name: "Placeholder Two")
    Penalties::Backfill::ENTRIES[990_002] = {
      name: "Placeholder Two",
      category: :voter_expertise,
      description: "Another test description."
    }

    Penalties::Backfill.call
    first = penalty.reload.updated_at

    Penalties::Backfill.call

    assert_equal first, penalty.reload.updated_at
  ensure
    Penalties::Backfill::ENTRIES.delete(990_002)
  end

  test "skips ids that are not present without raising" do
    baseline = Penalties::Backfill.call[:not_found]

    Penalties::Backfill::ENTRIES[990_003] = {name: "Absent Penalty", category: :list_integrity, description: "Absent."}

    result = nil
    assert_nothing_raised { result = Penalties::Backfill.call }
    assert_equal baseline + 1, result[:not_found]
    assert_empty result[:mismatched]
  ensure
    Penalties::Backfill::ENTRIES.delete(990_003)
  end

  test "a mismatched name is skipped, reported, and does not touch the row" do
    penalty = Penalty.create!(id: 990_004, type: "Global::Penalty", name: "The Real Name")
    Penalties::Backfill::ENTRIES[990_004] = {
      name: "A Different Expected Name",
      category: :list_integrity,
      description: "This must never be written."
    }

    result = Penalties::Backfill.call

    penalty.reload
    assert_nil penalty.category
    assert_nil penalty.description
    assert_equal 0, result[:updated]
    assert_equal 1, result[:mismatched].size

    mismatch = result[:mismatched].first
    assert_equal 990_004, mismatch[:id]
    assert_equal "A Different Expected Name", mismatch[:expected]
    assert_equal "The Real Name", mismatch[:found]
  ensure
    Penalties::Backfill::ENTRIES.delete(990_004)
  end

  test "the mismatch path does not raise" do
    Penalty.create!(id: 990_005, type: "Global::Penalty", name: "Actual Name")
    Penalties::Backfill::ENTRIES[990_005] = {
      name: "Expected Name",
      category: :list_integrity,
      description: "Irrelevant."
    }

    assert_nothing_raised { Penalties::Backfill.call }
  ensure
    Penalties::Backfill::ENTRIES.delete(990_005)
  end

  test "the task exits non-zero and prints the mismatch when a name does not match" do
    Penalty.create!(id: 990_006, type: "Global::Penalty", name: "Actual Name")
    Penalties::Backfill::ENTRIES[990_006] = {
      name: "Expected Name",
      category: :list_integrity,
      description: "Irrelevant."
    }

    out, = capture_io do
      assert_raises(SystemExit) { @task.invoke }
    end

    assert_match(/MISMATCHED \(skipped\): 990006 expected "Expected Name" found "Actual Name"/, out)
  ensure
    Penalties::Backfill::ENTRIES.delete(990_006)
  end

  test "every entry names a real category, a description and a name" do
    valid = Penalty.categories.keys.map(&:to_sym)
    Penalties::Backfill::ENTRIES.each do |id, entry|
      assert_includes valid, entry[:category], "penalty #{id} has an unknown category"
      assert entry[:description].present?, "penalty #{id} has a blank description"
      assert entry[:name].present?, "penalty #{id} has a blank name"
    end
  end

  test "the task runs" do
    # capture_io: the task narrates its result on stdout, and `bin/rails test`
    # is expected to run clean. No mismatches are expected against the real
    # ENTRIES set here (see the dedicated mismatch tests above for that path),
    # so the task must complete without exiting.
    capture_io { @task.invoke }
    assert true
  end
end
