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

        test "empty? is true for identical snapshots and false otherwise" do
          assert Diff.empty?(Diff.call(before: snap, after: snap))
          assert_not Diff.empty?(Diff.call(before: snap, after: snap("name" => "B")))
        end
      end
    end
  end
end
