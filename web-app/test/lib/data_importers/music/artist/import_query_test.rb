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
            musicbrainz_id: nil,
            options: {year_formed: 1965}
          }

          assert_equal expected, query.to_h
        end

        test "to_h with no options" do
          query = ImportQuery.new(name: "David Bowie")

          expected = {
            name: "David Bowie",
            musicbrainz_id: nil,
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

        # Tests for new MusicBrainz ID functionality
        test "initializes with musicbrainz_id and options" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
          query = ImportQuery.new(musicbrainz_id: mbid, country: "GB")

          assert_equal mbid, query.musicbrainz_id
          assert_nil query.name
          assert_equal({country: "GB"}, query.options)
        end

        test "initializes with musicbrainz_id only" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
          query = ImportQuery.new(musicbrainz_id: mbid)

          assert_equal mbid, query.musicbrainz_id
          assert_nil query.name
          assert_equal({}, query.options)
        end

        test "initializes with both name and musicbrainz_id" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
          query = ImportQuery.new(name: "Depeche Mode", musicbrainz_id: mbid)

          assert_equal "Depeche Mode", query.name
          assert_equal mbid, query.musicbrainz_id
          assert_equal({}, query.options)
        end

        test "valid? returns true when musicbrainz_id is present" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
          query = ImportQuery.new(musicbrainz_id: mbid)
          assert query.valid?
        end

        test "valid? returns true when both name and musicbrainz_id are present" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
          query = ImportQuery.new(name: "Depeche Mode", musicbrainz_id: mbid)
          assert query.valid?
        end

        test "valid? returns false when both name and musicbrainz_id are blank" do
          query = ImportQuery.new(name: "", musicbrainz_id: "")
          refute query.valid?
        end

        test "valid? returns false when both name and musicbrainz_id are nil" do
          query = ImportQuery.new(name: nil, musicbrainz_id: nil)
          refute query.valid?
        end

        test "valid? returns false when musicbrainz_id is invalid UUID format" do
          query = ImportQuery.new(musicbrainz_id: "not-a-valid-uuid")
          refute query.valid?
        end

        test "valid? returns false when musicbrainz_id is too short" do
          query = ImportQuery.new(musicbrainz_id: "1234-5678")
          refute query.valid?
        end

        test "valid? returns false when musicbrainz_id has invalid characters" do
          query = ImportQuery.new(musicbrainz_id: "8538e728-ca0b-4321-b7e5-cff6565dd4cZ")
          refute query.valid?
        end

        test "to_h includes musicbrainz_id when present" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
          query = ImportQuery.new(musicbrainz_id: mbid, year_formed: 1980)

          expected = {
            name: nil,
            musicbrainz_id: mbid,
            options: {year_formed: 1980}
          }

          assert_equal expected, query.to_h
        end

        test "to_h includes both name and musicbrainz_id when both present" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
          query = ImportQuery.new(name: "Depeche Mode", musicbrainz_id: mbid)

          expected = {
            name: "Depeche Mode",
            musicbrainz_id: mbid,
            options: {}
          }

          assert_equal expected, query.to_h
        end

        test "musicbrainz_id is accessible as reader" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
          query = ImportQuery.new(musicbrainz_id: mbid)
          assert_respond_to query, :musicbrainz_id
          assert_equal mbid, query.musicbrainz_id
        end

        test "validate! raises error when both name and musicbrainz_id are blank" do
          query = ImportQuery.new(name: "", musicbrainz_id: nil)

          error = assert_raises(ArgumentError) do
            query.validate!
          end

          assert_includes error.message, "Either name or musicbrainz_id is required"
        end

        test "validate! raises error when musicbrainz_id format is invalid" do
          query = ImportQuery.new(musicbrainz_id: "invalid-format")

          error = assert_raises(ArgumentError) do
            query.validate!
          end

          assert_includes error.message, "MusicBrainz ID must be a valid UUID format"
        end

        test "validate! passes when valid musicbrainz_id is provided" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
          query = ImportQuery.new(musicbrainz_id: mbid)

          # Should not raise
          assert_nothing_raised do
            query.validate!
          end
        end
      end
    end
  end
end
