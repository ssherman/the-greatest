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
    assert_match(/\Athe_greatest_test_news_posts_[0-9a-f]{6}_wt\z/,
      TestDatabaseName.for("#{WORKTREES}/news-posts/web-app"))
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
    assert_match(/\Athe_greatest_test_feature_x_1_2_[0-9a-f]{6}_wt\z/,
      TestDatabaseName.for("#{WORKTREES}/feature.x-1 2/web-app"))
  end

  # 60 bytes, not 63: Rails' parallelize appends "-0".."-31" to whatever this
  # returns, and that suffix has to fit inside the identifier limit too.
  test "a name too long for Postgres is shortened" do
    long = "a-very-long-worktree-branch-name-that-runs-well-past-the-limit"
    assert_operator TestDatabaseName.for("#{WORKTREES}/#{long}/web-app").bytesize, :<=, 60
  end

  # parallelize() appends "_0".."_31" to whatever we return, using an
  # underscore -- the same character the slug uses for every character
  # Postgres will not take bare. Without a terminator that cannot end a worker
  # name, worktree "feature-1" would claim the database worktree "feature" is
  # already using for its worker 1. Both are plausible branch names.
  test "a worktree cannot claim another worktree's parallel worker database" do
    feature = TestDatabaseName.for("#{WORKTREES}/feature/web-app")
    refute_equal "#{feature}_1", TestDatabaseName.for("#{WORKTREES}/feature-1/web-app")
  end

  test "a worktree cannot claim the main checkout's parallel worker database" do
    refute_equal "#{TestDatabaseName.for(MAIN)}_1", TestDatabaseName.for("#{WORKTREES}/1/web-app")
  end

  # Sanitizing for Postgres is lossy -- "feature-x" and "feature_x" are
  # different worktrees that normalize to the same slug, as are two checkouts
  # of the same name under different parents. Both would silently share a
  # database, which is the collision this module exists to prevent.
  test "worktree names that normalize to the same slug stay distinct" do
    refute_equal TestDatabaseName.for("#{WORKTREES}/feature-x/web-app"),
      TestDatabaseName.for("#{WORKTREES}/feature_x/web-app")
  end

  test "same-named worktrees under different parents stay distinct" do
    refute_equal TestDatabaseName.for("/home/shane/dev/a/feature/web-app"),
      TestDatabaseName.for("/home/shane/dev/b/feature/web-app")
  end

  test "two over-long worktree names stay distinct after shortening" do
    prefix = "identical-leading-worktree-name-that-is-far-too-long-for-postgres"
    refute_equal TestDatabaseName.for("#{WORKTREES}/#{prefix}-one/web-app"),
      TestDatabaseName.for("#{WORKTREES}/#{prefix}-two/web-app")
  end
end
