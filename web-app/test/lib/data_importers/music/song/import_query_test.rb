# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Song
      class ImportQueryTest < ActiveSupport::TestCase
        test "initializes with title only" do
          query = ImportQuery.new(title: "Time")

          assert_equal "Time", query.title
          assert_nil query.musicbrainz_recording_id
          assert_equal({}, query.options)
        end

        test "initializes with musicbrainz_recording_id only" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(musicbrainz_recording_id: mbid)

          assert_equal mbid, query.musicbrainz_recording_id
          assert_nil query.title
          assert_equal({}, query.options)
        end

        test "initializes with both title and musicbrainz_recording_id" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(title: "Time", musicbrainz_recording_id: mbid)

          assert_equal "Time", query.title
          assert_equal mbid, query.musicbrainz_recording_id
        end

        test "initializes with additional options" do
          query = ImportQuery.new(title: "Time", force_update: true)

          assert_equal "Time", query.title
          assert_equal({force_update: true}, query.options)
        end

        test "valid? returns true when title is provided" do
          query = ImportQuery.new(title: "Time")
          assert query.valid?
        end

        test "valid? returns true when musicbrainz_recording_id is provided" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(musicbrainz_recording_id: mbid)
          assert query.valid?
        end

        test "valid? returns false when both title and musicbrainz_recording_id are blank" do
          query = ImportQuery.new(title: nil, musicbrainz_recording_id: nil)
          refute query.valid?
        end

        test "valid? returns false when title is empty string" do
          query = ImportQuery.new(title: "")
          refute query.valid?
        end

        test "valid? returns false when title is not a string" do
          query = ImportQuery.new(title: 123)
          refute query.valid?
        end

        test "valid? returns false when musicbrainz_recording_id is not a string" do
          query = ImportQuery.new(musicbrainz_recording_id: 123)
          refute query.valid?
        end

        test "valid? returns false when musicbrainz_recording_id is invalid UUID format" do
          query = ImportQuery.new(musicbrainz_recording_id: "not-a-valid-uuid")
          refute query.valid?
        end

        test "valid? returns false when musicbrainz_recording_id is too short" do
          query = ImportQuery.new(musicbrainz_recording_id: "1234-5678")
          refute query.valid?
        end

        test "valid? returns false when musicbrainz_recording_id has invalid characters" do
          query = ImportQuery.new(musicbrainz_recording_id: "6b9a9e04-abd7-4666-86ba-bb220ef4c3bZ")
          refute query.valid?
        end

        test "validate! raises ArgumentError when both title and musicbrainz_recording_id are blank" do
          query = ImportQuery.new(title: nil, musicbrainz_recording_id: nil)

          error = assert_raises(ArgumentError) do
            query.validate!
          end

          assert_includes error.message, "Either title or musicbrainz_recording_id is required"
        end

        test "validate! raises ArgumentError when title is not a string" do
          query = ImportQuery.new(title: 123)

          error = assert_raises(ArgumentError) do
            query.validate!
          end

          assert_includes error.message, "Title must be a string"
        end

        test "validate! raises ArgumentError when musicbrainz_recording_id is not a string" do
          query = ImportQuery.new(musicbrainz_recording_id: 123)

          error = assert_raises(ArgumentError) do
            query.validate!
          end

          assert_includes error.message, "MusicBrainz recording ID must be a string"
        end

        test "validate! raises ArgumentError when musicbrainz_recording_id format is invalid" do
          query = ImportQuery.new(musicbrainz_recording_id: "invalid-format")

          error = assert_raises(ArgumentError) do
            query.validate!
          end

          assert_includes error.message, "MusicBrainz recording ID must be a valid UUID format"
        end

        test "validate! passes when valid title is provided" do
          query = ImportQuery.new(title: "Time")

          assert_nothing_raised do
            query.validate!
          end
        end

        test "validate! passes when valid musicbrainz_recording_id is provided" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(musicbrainz_recording_id: mbid)

          assert_nothing_raised do
            query.validate!
          end
        end

        test "to_h returns hash with all attributes" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(title: "Time", musicbrainz_recording_id: mbid, force_update: true)

          hash = query.to_h

          assert_equal "Time", hash[:title]
          assert_equal mbid, hash[:musicbrainz_recording_id]
          assert_equal({force_update: true}, hash[:options])
        end

        test "title is accessible as reader" do
          query = ImportQuery.new(title: "Time")
          assert_respond_to query, :title
          assert_equal "Time", query.title
        end

        test "musicbrainz_recording_id is accessible as reader" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(musicbrainz_recording_id: mbid)
          assert_respond_to query, :musicbrainz_recording_id
          assert_equal mbid, query.musicbrainz_recording_id
        end

        test "options is accessible as reader" do
          query = ImportQuery.new(title: "Time", force_update: true)
          assert_respond_to query, :options
          assert_equal({force_update: true}, query.options)
        end
      end
    end
  end
end
