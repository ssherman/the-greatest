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
      end
    end
  end
end
