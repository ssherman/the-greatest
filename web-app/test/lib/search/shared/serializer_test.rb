# frozen_string_literal: true

require "test_helper"

module Search
  module Shared
    class SerializerTest < ActiveSupport::TestCase
      setup { @serializer = Search::Shared::Serializer.new }

      test "round-trips a nested document" do
        doc = {"title" => "Kid A", "artists" => ["Radiohead"], "year" => 2000}

        assert_equal doc, @serializer.load(@serializer.dump(doc))
      end

      test "parses to string keys, matching the serializer it replaces" do
        assert_equal({"a" => 1}, @serializer.load(%({"a":1})))
      end

      test "never touches the deprecated MultiJSON aliases" do
        # The entire point of this class. Note this CANNOT be written as
        # `MultiJSON.expects(:generate)` -- the deprecated `MultiJson.dump`
        # forwards to `generate`, so that expectation is satisfied either way
        # and passes against the very code it is meant to reject (confirmed
        # during planning). Guarding the deprecated names with `.never` is what
        # actually discriminates.
        ::MultiJSON.expects(:dump).never
        ::MultiJSON.expects(:load).never

        assert_equal({"a" => 1}, @serializer.load(@serializer.dump({"a" => 1})))
      end
    end
  end
end
