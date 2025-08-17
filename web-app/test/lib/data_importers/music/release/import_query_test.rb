# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Release
      class ImportQueryTest < ActiveSupport::TestCase
        def setup
          @album = music_albums(:dark_side_of_the_moon)
        end

        test "initializes with album" do
          query = ImportQuery.new(album: @album)

          assert_equal @album, query.album
        end

        test "valid? returns true when album is present and persisted" do
          query = ImportQuery.new(album: @album)
          assert query.valid?
        end

        test "valid? returns false when album is nil" do
          query = ImportQuery.new(album: nil)
          refute query.valid?
        end

        test "valid? returns false when album is not a Music::Album" do
          non_album = users(:regular_user)
          query = ImportQuery.new(album: non_album)
          refute query.valid?
        end

        test "valid? returns false when album is not persisted" do
          unpersisted_album = ::Music::Album.new(title: "New Album")
          query = ImportQuery.new(album: unpersisted_album)
          refute query.valid?
        end

        test "validate! raises ArgumentError when album is missing" do
          query = ImportQuery.new(album: nil)
          assert_raises ArgumentError, "Album is required" do
            query.validate!
          end
        end

        test "validate! raises ArgumentError when album is wrong type" do
          query = ImportQuery.new(album: users(:regular_user))
          assert_raises ArgumentError, "Album must be a Music::Album" do
            query.validate!
          end
        end

        test "validate! raises ArgumentError when album is not persisted" do
          unpersisted_album = ::Music::Album.new(title: "New Album")
          query = ImportQuery.new(album: unpersisted_album)
          assert_raises ArgumentError, "Album must be persisted" do
            query.validate!
          end
        end

        test "validate! does not raise when album is valid" do
          query = ImportQuery.new(album: @album)
          assert_nothing_raised do
            query.validate!
          end
        end

        test "album is accessible as reader" do
          query = ImportQuery.new(album: @album)
          assert_respond_to query, :album
          assert_equal @album, query.album
        end
      end
    end
  end
end
