require "test_helper"

class Services::BooksMigration::UserListItemPlanTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def route(redirects: [])
    Services::BooksMigration::BookRoute.new(sync_scope(redirects: redirects), book_ids_here: Set[10, 20, 30])
  end

  def row(id, list_id, book_id, position)
    {"id" => id, "user_list_id" => list_id, "book_id" => book_id, "position" => position}
  end

  test "counts as inserted only the items not already here" do
    plan = Services::BooksMigration::UserListItemPlan.call(
      [row(1, 7, 10, 1), row(2, 7, 20, 2)], [[90, 7, "Books::Book", 10]], route
    )

    assert_equal [[7, 10], [7, 20]], plan.keep.keys
    assert_equal 1, plan.inserted
    assert_empty plan.stale_ids
  end

  test "an item here that legacy does not have is stale, whatever its type" do
    plan = Services::BooksMigration::UserListItemPlan.call(
      [row(1, 7, 10, 1)], [[90, 7, "Books::Book", 30], [91, 7, "Games::Game", 10]], route
    )

    assert_equal [90, 91], plan.stale_ids
  end

  test "a null position sorts last when collapsing a collision" do
    plan = Services::BooksMigration::UserListItemPlan.call(
      [row(1, 7, 5, nil), row(2, 7, 20, 4)], [], route(redirects: [["Books::Book", 5, 20]])
    )

    assert_equal 2, plan.keep[[7, 20]]["id"]
    assert_equal 1, plan.collisions
  end

  test "collects missing books instead of raising" do
    plan = Services::BooksMigration::UserListItemPlan.call([row(1, 7, 99, 1)], [], route)

    assert_equal [1], plan.missing
  end

  def hold_for(pairs)
    Services::BooksMigration::ReimportHold.new(pairs: pairs, redirects: Services::BooksMigration::Redirects.new([]))
  end

  def plan_with_hold(legacy, here, pairs, redirects: [], list_users: {7 => 70})
    Services::BooksMigration::UserListItemPlan.call(
      legacy, here, route(redirects: redirects), hold: hold_for(pairs), list_users: list_users
    )
  end

  test "a legacy row on a held book is neither kept nor inserted" do
    plan = plan_with_hold([row(1, 7, 10, 1)], [], [[70, 10]])

    assert_empty plan.keep
    assert_equal 0, plan.inserted
    assert_equal 1, plan.held_legacy
  end

  test "a legacy row whose routed book is held is skipped" do
    plan = plan_with_hold([row(1, 7, 5, 1)], [], [[70, 20]], redirects: [["Books::Book", 5, 20]])

    assert_empty plan.keep
    assert_equal 1, plan.held_legacy
  end

  test "a row here on a held book is not stale" do
    plan = plan_with_hold([], [[90, 7, "Books::Book", 30]], [[70, 30]])

    assert_empty plan.stale_ids
    assert_equal 1, plan.held_here
  end

  test "holds the pair in every list of the reader" do
    plan = plan_with_hold(
      [row(1, 7, 10, 1), row(2, 8, 10, 1)], [[90, 7, "Books::Book", 10], [91, 8, "Books::Book", 10]],
      [[70, 10]], list_users: {7 => 70, 8 => 70}
    )

    assert_empty plan.keep
    assert_empty plan.stale_ids
    assert_equal [2, 2], [plan.held_legacy, plan.held_here]
  end

  test "another reader's row on the same book still syncs" do
    plan = plan_with_hold([row(1, 9, 10, 1)], [], [[70, 10]], list_users: {7 => 70, 9 => 71})

    assert_equal [[9, 10]], plan.keep.keys
    assert_equal 0, plan.held_legacy
  end
end
