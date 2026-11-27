require "test_helper"

module Services
  module Lists
    module Audits
      class DiffTest < ActiveSupport::TestCase
        def snap(fields = {}, penalties = [])
          {"fields" => {"name" => "A", "year_published" => 1990}.merge(fields), "penalties" => penalties}
        end

        test "changed fields appear with from and to, unchanged ones do not" do
          diff = Diff.call(before: snap, after: snap("name" => "B"))
          assert_equal({"name" => {"from" => "A", "to" => "B"}}, diff["fields"])
        end

        test "attached and detached penalties land in their arrays" do
          a = {"id" => 1, "name" => "One"}
          b = {"id" => 2, "name" => "Two"}
          diff = Diff.call(before: snap({}, [a]), after: snap({}, [b]))
          assert_equal [b], diff["penalties_attached"]
          assert_equal [a], diff["penalties_detached"]
        end

        test "a missing field against a nil one is no change, and a value is from nil to it" do
          assert_equal({}, Diff.call(before: {"fields" => {}}, after: {"fields" => {"voter_details" => nil}})["fields"])
          diff = Diff.call(before: {"fields" => {}}, after: {"fields" => {"voter_details" => "Jane"}})
          assert_equal({"voter_details" => {"from" => nil, "to" => "Jane"}}, diff["fields"])
        end

        def with_items(items)
          snap.merge("items" => items)
        end

        def row(id, book_id, position)
          {"id" => id, "book_id" => book_id, "position" => position}
        end

        test "added, removed, relinked and moved rows are each reported" do
          before = with_items([row(1, 10, 1), row(2, 20, 2), row(3, 30, 3), row(4, 40, 4)])
          after = with_items([row(1, 10, 1), row(3, 31, 3), row(4, 40, 9), row(5, 50, 5)])
          diff = Diff.call(before: before, after: after)
          assert_equal [row(5, 50, 5)], diff["items_added"]
          assert_equal [row(2, 20, 2)], diff["items_removed"]
          assert_equal [
            {"id" => 3, "book_id" => {"from" => 30, "to" => 31}},
            {"id" => 4, "position" => {"from" => 4, "to" => 9}}
          ], diff["items_changed"]
        end

        test "a before snapshot with no items key reports no item changes" do
          diff = Diff.call(before: snap, after: with_items([row(1, 10, 1)]))
          assert_equal [], diff["items_added"]
          assert_equal [], diff["items_removed"]
          assert_equal [], diff["items_changed"]
          assert Diff.empty?(diff)
        end

        test "only item changes is not empty" do
          diff = Diff.call(before: with_items([]), after: with_items([row(1, 10, 1)]))
          assert_not Diff.empty?(diff)
        end

        test "empty? is true for identical snapshots and false otherwise" do
          assert Diff.empty?(Diff.call(before: snap, after: snap))
          assert_not Diff.empty?(Diff.call(before: snap, after: snap("name" => "B")))
        end
      end
    end
  end
end
