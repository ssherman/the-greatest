require "test_helper"

class Services::BooksMigration::DeletionGuardTest < ActiveSupport::TestCase
  def with_env(name, value)
    previous = ENV[name]
    ENV[name] = value
    yield
  ensure
    ENV[name] = previous
  end

  test "allows up to the floor whatever the table size" do
    assert_nil Services::BooksMigration.guard_deletion!("user_lists", 500, 600)
  end

  test "allows up to five percent of a large table" do
    assert_nil Services::BooksMigration.guard_deletion!("user_lists", 30_000, 600_000)
  end

  test "refuses past both, naming the table and the counts" do
    error = assert_raises(RuntimeError) { Services::BooksMigration.guard_deletion!("reviews", 501, 600) }

    assert_includes error.message, "reviews"
    assert_includes error.message, "501 of 600"
    assert_includes error.message, "SYNC_ALLOW_DELETES=1"
  end

  test "SYNC_ALLOW_DELETES=1 lets it through" do
    with_env("SYNC_ALLOW_DELETES", "1") do
      assert_nil Services::BooksMigration.guard_deletion!("reviews", 600, 600)
    end
  end
end
