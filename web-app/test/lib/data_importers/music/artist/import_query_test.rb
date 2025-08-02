# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Artist
      class ImportQueryTest < ActiveSupport::TestCase
        test "initializes with name and options" do
          query = ImportQuery.new(name: "Pink Floyd", country: "GB")

          assert_equal "Pink Floyd", query.name
          assert_equal({country: "GB"}, query.options)
        end

        test "initializes with name only" do
          query = ImportQuery.new(name: "David Bowie")

          assert_equal "David Bowie", query.name
          assert_equal({}, query.options)
        end

        test "valid? returns true when name is present" do
          query = ImportQuery.new(name: "The Beatles")
          assert query.valid?
        end

        test "valid? returns false when name is blank string" do
          query = ImportQuery.new(name: "")
          refute query.valid?
        end

        test "valid? returns false when name is nil" do
          query = ImportQuery.new(name: nil)
          refute query.valid?
        end

        test "valid? returns false when name is whitespace only" do
          query = ImportQuery.new(name: "   ")
          refute query.valid?
        end

        test "to_h returns hash representation" do
          query = ImportQuery.new(name: "Pink Floyd", year_formed: 1965)

          expected = {
            name: "Pink Floyd",
            options: {year_formed: 1965}
          }

          assert_equal expected, query.to_h
        end

        test "to_h with no options" do
          query = ImportQuery.new(name: "David Bowie")

          expected = {
            name: "David Bowie",
            options: {}
          }

          assert_equal expected, query.to_h
        end

        test "handles complex options" do
          options = {
            country: "GB",
            year_formed: 1965,
            force_update: true
          }

          query = ImportQuery.new(name: "Pink Floyd", **options)

          assert_equal "Pink Floyd", query.name
          assert_equal options, query.options
        end

        test "name is accessible as reader" do
          query = ImportQuery.new(name: "Roger Waters")
          assert_respond_to query, :name
          assert_equal "Roger Waters", query.name
        end

        test "options is accessible as reader" do
          query = ImportQuery.new(name: "David Gilmour", instrument: "guitar")
          assert_respond_to query, :options
          assert_equal({instrument: "guitar"}, query.options)
        end
      end
    end
  end
end
