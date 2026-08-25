require "test_helper"

module Services
  module Corrections
    class ValueCasterTest < ActiveSupport::TestCase
      test "strips and returns a string" do
        assert_equal "War and Peace", ValueCaster.call("  War and Peace  ", type: :string)
      end

      test "returns nil for a blank string" do
        assert_nil ValueCaster.call("   ", type: :string)
      end

      test "treats text like string" do
        assert_equal "A summary.", ValueCaster.call(" A summary. ", type: :text)
      end

      test "casts a numeric string to an integer" do
        assert_equal 1869, ValueCaster.call(" 1869 ", type: :integer)
      end

      # Legacy used value.to_i, which turns "not a year" into 0 and would have
      # silently set first_published_year to 0 on apply.
      test "returns nil rather than zero for a non-numeric integer" do
        assert_nil ValueCaster.call("not a year", type: :integer)
      end

      test "returns nil for a blank integer" do
        assert_nil ValueCaster.call("", type: :integer)
      end

      test "passes an integer through" do
        assert_equal 1869, ValueCaster.call(1869, type: :integer)
      end

      test "compacts, strips and dedupes a string array" do
        assert_equal ["Voyna i mir", "War & Peace"],
          ValueCaster.call([" Voyna i mir ", "", "War & Peace", "Voyna i mir"], type: :string_array)
      end

      test "returns an empty array for a nil string array" do
        assert_equal [], ValueCaster.call(nil, type: :string_array)
      end

      test "raises on an unknown type" do
        assert_raises(ArgumentError) { ValueCaster.call("x", type: :nonsense) }
      end
    end
  end
end
