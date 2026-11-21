require "test_helper"

module Services
  module Penalties
    class LoadGuidanceTest < ActiveSupport::TestCase
      setup do
        @penalty = penalties(:static_penalty)
        @penalty.update_columns(guidance: nil)
      end

      def entry(guidance: "Rule")
        {"id" => @penalty.id, "name" => @penalty.name, "guidance" => guidance}
      end

      test "fills blank guidance when id and name match" do
        result = LoadGuidance.call(entries: [entry])

        assert result.success?
        assert_equal [@penalty.id], result.data[:filled]
        assert_equal "Rule", @penalty.reload.guidance
      end

      test "leaves non-blank guidance alone" do
        @penalty.update_columns(guidance: "Edited by hand")

        result = LoadGuidance.call(entries: [entry])

        assert_equal [@penalty.id], result.data[:skipped_present]
        assert_empty result.data[:filled]
        assert_equal "Edited by hand", @penalty.reload.guidance
      end

      test "reports a name mismatch without writing" do
        result = LoadGuidance.call(entries: [entry.merge("name" => "Something else")])

        assert_equal [{id: @penalty.id, expected: "Something else", actual: @penalty.name}], result.data[:mismatched]
        assert_nil @penalty.reload.guidance
      end

      test "reports an id with no row as missing" do
        result = LoadGuidance.call(entries: [{"id" => 0, "name" => "x", "guidance" => "y"}])

        assert_equal [0], result.data[:missing]
      end

      test "running twice changes nothing the second time" do
        LoadGuidance.call(entries: [entry])
        result = LoadGuidance.call(entries: [entry(guidance: "Other")])

        assert_empty result.data[:filled]
        assert_equal [@penalty.id], result.data[:skipped_present]
        assert_equal "Rule", @penalty.reload.guidance
      end
    end
  end
end
