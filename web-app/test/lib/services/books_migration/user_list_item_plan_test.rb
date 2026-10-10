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
end
