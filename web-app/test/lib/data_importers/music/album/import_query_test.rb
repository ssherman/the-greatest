# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Album
      class ImportQueryTest < ActiveSupport::TestCase
        def setup
          @artist = music_artists(:pink_floyd)
        end

        test "initializes with artist and title" do
          query = ImportQuery.new(artist: @artist, title: "The Wall")

          assert_equal @artist, query.artist
          assert_equal "The Wall", query.title
          assert_equal false, query.primary_albums_only
        end

        test "initializes with artist only" do
          query = ImportQuery.new(artist: @artist)

          assert_equal @artist, query.artist
          assert_nil query.title
          assert_equal false, query.primary_albums_only
        end

        test "initializes with primary_albums_only option" do
          query = ImportQuery.new(artist: @artist, primary_albums_only: true)

          assert_equal @artist, query.artist
          assert_equal true, query.primary_albums_only
        end

        test "valid? returns true when artist is present and persisted" do
          query = ImportQuery.new(artist: @artist)
          assert query.valid?
        end

        test "valid? returns false when artist is nil" do
          query = ImportQuery.new(artist: nil)
          refute query.valid?
        end

        test "valid? returns false when artist is not a Music::Artist" do
          non_artist = users(:regular_user)
          query = ImportQuery.new(artist: non_artist)
          refute query.valid?
        end

        test "valid? returns false when artist is not persisted" do
          unpersisted_artist = ::Music::Artist.new(name: "New Artist")
          query = ImportQuery.new(artist: unpersisted_artist)
          refute query.valid?
        end

        test "valid? returns false when title is not a string" do
          query = ImportQuery.new(artist: @artist, title: 123)
          refute query.valid?
        end

        test "valid? returns true when title is nil" do
          query = ImportQuery.new(artist: @artist, title: nil)
          assert query.valid?
        end

        test "valid? returns true when title is empty string" do
          query = ImportQuery.new(artist: @artist, title: "")
          assert query.valid?
        end

        test "validate! raises ArgumentError when artist is missing" do
          query = ImportQuery.new(artist: nil)
          assert_raises ArgumentError do
            query.validate!
          end
        end

        test "validate! raises ArgumentError when artist is wrong type" do
          query = ImportQuery.new(artist: users(:regular_user))
          assert_raises ArgumentError do
            query.validate!
          end
        end

        test "validate! raises ArgumentError when artist is not persisted" do
          unpersisted_artist = ::Music::Artist.new(name: "New Artist")
          query = ImportQuery.new(artist: unpersisted_artist)
          assert_raises ArgumentError do
            query.validate!
          end
        end

        test "validate! raises ArgumentError when title is wrong type" do
          query = ImportQuery.new(artist: @artist, title: 123)
          assert_raises ArgumentError do
            query.validate!
          end
        end

        test "handles complex options" do
          query = ImportQuery.new(
            artist: @artist,
            title: "The Wall",
            primary_albums_only: true,
            force_update: true
          )

          assert_equal @artist, query.artist
          assert_equal "The Wall", query.title
          assert_equal true, query.primary_albums_only
          assert_equal({force_update: true}, query.options)
        end

        test "artist is accessible as reader" do
          query = ImportQuery.new(artist: @artist)
          assert_respond_to query, :artist
          assert_equal @artist, query.artist
        end

        test "title is accessible as reader" do
          query = ImportQuery.new(artist: @artist, title: "Animals")
          assert_respond_to query, :title
          assert_equal "Animals", query.title
        end

        test "primary_albums_only is accessible as reader" do
          query = ImportQuery.new(artist: @artist, primary_albums_only: true)
          assert_respond_to query, :primary_albums_only
          assert_equal true, query.primary_albums_only
        end

        # Tests for new MusicBrainz Release Group ID functionality
        test "initializes with release_group_musicbrainz_id only" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(release_group_musicbrainz_id: mbid)

          assert_equal mbid, query.release_group_musicbrainz_id
          assert_nil query.artist
          assert_nil query.title
          assert_equal false, query.primary_albums_only
          assert_equal({}, query.options)
        end

        test "initializes with release_group_musicbrainz_id and options" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(release_group_musicbrainz_id: mbid, primary_albums_only: true)

          assert_equal mbid, query.release_group_musicbrainz_id
          assert_nil query.artist
          assert_equal true, query.primary_albums_only
          assert_equal({}, query.options)
        end

        test "initializes with both artist and release_group_musicbrainz_id" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(artist: @artist, release_group_musicbrainz_id: mbid, title: "Test Album")

          assert_equal @artist, query.artist
          assert_equal "Test Album", query.title
          assert_equal mbid, query.release_group_musicbrainz_id
        end

        test "valid? returns true when release_group_musicbrainz_id is present" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(release_group_musicbrainz_id: mbid)
          assert query.valid?
        end

        test "valid? returns true when both artist and release_group_musicbrainz_id are present" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(artist: @artist, release_group_musicbrainz_id: mbid)
          assert query.valid?
        end

        test "valid? returns false when both artist and release_group_musicbrainz_id are nil" do
          query = ImportQuery.new(artist: nil, release_group_musicbrainz_id: nil)
          refute query.valid?
        end

        test "valid? returns false when both artist and release_group_musicbrainz_id are blank" do
          query = ImportQuery.new(artist: nil, release_group_musicbrainz_id: "")
          refute query.valid?
        end

        test "valid? returns false when release_group_musicbrainz_id is invalid UUID format" do
          query = ImportQuery.new(release_group_musicbrainz_id: "not-a-valid-uuid")
          refute query.valid?
        end

        test "valid? returns false when release_group_musicbrainz_id is too short" do
          query = ImportQuery.new(release_group_musicbrainz_id: "1234-5678")
          refute query.valid?
        end

        test "valid? returns false when release_group_musicbrainz_id has invalid characters" do
          query = ImportQuery.new(release_group_musicbrainz_id: "6b9a9e04-abd7-4666-86ba-bb220ef4c3bZ")
          refute query.valid?
        end

        test "release_group_musicbrainz_id is accessible as reader" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(release_group_musicbrainz_id: mbid)
          assert_respond_to query, :release_group_musicbrainz_id
          assert_equal mbid, query.release_group_musicbrainz_id
        end

        test "validate! raises error when both artist and release_group_musicbrainz_id are blank" do
          query = ImportQuery.new(artist: nil, release_group_musicbrainz_id: "")

          error = assert_raises(ArgumentError) do
            query.validate!
          end

          assert_includes error.message, "Either artist or release_group_musicbrainz_id is required"
        end

        test "validate! raises error when release_group_musicbrainz_id format is invalid" do
          query = ImportQuery.new(release_group_musicbrainz_id: "invalid-format")

          error = assert_raises(ArgumentError) do
            query.validate!
          end

          assert_includes error.message, "Release Group MusicBrainz ID must be a valid UUID"
        end

        test "validate! passes when valid release_group_musicbrainz_id is provided" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(release_group_musicbrainz_id: mbid)

          # Should not raise
          assert_nothing_raised do
            query.validate!
          end
        end

        test "validate! passes when both artist and release_group_musicbrainz_id are provided" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
          query = ImportQuery.new(artist: @artist, release_group_musicbrainz_id: mbid)

          # Should not raise
          assert_nothing_raised do
            query.validate!
          end
        end
      end
    end
  end
end
