# frozen_string_literal: true

require "test_helper"
require Rails.root.join("config/test_database_name").to_s

# Guards the derivation that gives every git worktree its own test database.
#
# config/database.yml is identical in every checkout, so before this existed
# each worktree resolved to the same `the_greatest_test` (and the same
# `the_greatest_test-0..N` parallel worker databases). Two agents running
# `bin/rails test` at once truncated each other's fixtures, which surfaces as
# phantom failures -- missing routes, nil controllers -- in a suite that is
# actually green.
#
# Every failure mode here is SILENT: a derivation that quietly returns the same
# name for two different checkouts reintroduces that bug with no error to
# notice. That is what these tests exist to catch, which is also why the
# length case matters -- Postgres truncates identifiers at 63 bytes without
# complaining, so two long worktree names could collapse into one database.
class TestDatabaseNameTest < ActiveSupport::TestCase
  MAIN = "/home/shane/dev/the-greatest/web-app"
  WORKTREES = "/home/shane/dev/the-greatest/.claude/worktrees"

  test "the main checkout keeps the canonical database name" do
    assert_equal "the_greatest_test", TestDatabaseName.for(MAIN)
  end

  test "a worktree gets a database name of its own" do
    assert_equal "the_greatest_test_news_posts",
      TestDatabaseName.for("#{WORKTREES}/news-posts/web-app")
  end

  test "two worktrees never share a database name" do
    refute_equal TestDatabaseName.for("#{WORKTREES}/books-saved-searches-inc5/web-app"),
      TestDatabaseName.for("#{WORKTREES}/books-western-canon-penalty/web-app")
  end

  test "a worktree never collides with the main checkout" do
    refute_equal TestDatabaseName.for(MAIN),
      TestDatabaseName.for("#{WORKTREES}/record-merge/web-app")
  end

  test "characters Postgres cannot take in a bare identifier are replaced" do
    assert_equal "the_greatest_test_feature_x_1_2",
      TestDatabaseName.for("#{WORKTREES}/feature.x-1 2/web-app")
  end

  # 60 bytes, not 63: Rails' parallelize appends "-0".."-31" to whatever this
  # returns, and that suffix has to fit inside the identifier limit too.
  test "a name too long for Postgres is shortened" do
    long = "a-very-long-worktree-branch-name-that-runs-well-past-the-limit"
    assert_operator TestDatabaseName.for("#{WORKTREES}/#{long}/web-app").bytesize, :<=, 60
  end

  test "two over-long worktree names stay distinct after shortening" do
    prefix = "identical-leading-worktree-name-that-is-far-too-long-for-postgres"
    refute_equal TestDatabaseName.for("#{WORKTREES}/#{prefix}-one/web-app"),
      TestDatabaseName.for("#{WORKTREES}/#{prefix}-two/web-app")
  end
end
