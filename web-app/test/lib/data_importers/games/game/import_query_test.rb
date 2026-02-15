# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Games
    module Game
      class ImportQueryTest < ActiveSupport::TestCase
        test "valid? returns true for valid igdb_id" do
          query = ImportQuery.new(igdb_id: 7346)
          assert query.valid?
        end

        test "valid? returns false when igdb_id is missing" do
          query = ImportQuery.new
          refute query.valid?
        end

        test "valid? returns false when igdb_id is not an integer" do
          query = ImportQuery.new(igdb_id: "7346")
          refute query.valid?
        end

        test "valid? returns false when igdb_id is negative" do
          query = ImportQuery.new(igdb_id: -1)
          refute query.valid?
        end

        test "valid? returns false when igdb_id is zero" do
          query = ImportQuery.new(igdb_id: 0)
          refute query.valid?
        end

        test "validate! raises ArgumentError with descriptive message" do
          query = ImportQuery.new
          error = assert_raises(ArgumentError) { query.validate! }
          assert_includes error.message, "igdb_id is required"
        end

        test "to_h returns query parameters" do
          query = ImportQuery.new(igdb_id: 7346, extra: "option")
          hash = query.to_h

          assert_equal 7346, hash[:igdb_id]
          assert_equal({extra: "option"}, hash[:options])
        end
      end
    end
  end
end
