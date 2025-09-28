# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Album
      module Providers
        class AiDescriptionTest < ActiveSupport::TestCase
          def setup
            @provider = AiDescription.new
            @artist = music_artists(:pink_floyd)
            @query = ImportQuery.new(artist: @artist, title: "The Wall")
            @album = music_albums(:dark_side_of_the_moon) # Use existing album from fixtures
          end

          test "populate launches AlbumDescriptionJob and returns success" do
            ::Music::AlbumDescriptionJob.expects(:perform_async).with(@album.id)

            result = @provider.populate(@album, query: @query)

            assert result.success?
            assert_equal [:ai_description_queued], result.data_populated
          end

          test "populate returns failure when album has no title" do
            @album.title = nil

            result = @provider.populate(@album, query: @query)

            refute result.success?
            assert_includes result.errors, "Album title required for AI description"
          end

          test "populate returns failure when album has blank title" do
            @album.title = ""

            result = @provider.populate(@album, query: @query)

            refute result.success?
            assert_includes result.errors, "Album title required for AI description"
          end

          test "populate returns failure when album has no artists" do
            @album.album_artists.clear

            result = @provider.populate(@album, query: @query)

            refute result.success?
            assert_includes result.errors, "Album must have at least one artist for AI description"
          end

          test "populate returns failure when album artists collection is empty" do
            @album.stubs(:artists).returns([])

            result = @provider.populate(@album, query: @query)

            refute result.success?
            assert_includes result.errors, "Album must have at least one artist for AI description"
          end

          test "populate returns failure when album is not persisted" do
            # Create a new, non-persisted album with artists
            unpersisted_album = ::Music::Album.new(title: "New Album")
            unpersisted_album.album_artists.build(artist: @artist, position: 1)
            # Stub the artists association to return the artist (simulates the association being loaded)
            unpersisted_album.stubs(:artists).returns([@artist])

            result = @provider.populate(unpersisted_album, query: @query)

            refute result.success?
            assert_includes result.errors, "Album must be persisted before queuing AI description job"
          end

          test "populate works with item-based import when query is nil" do
            ::Music::AlbumDescriptionJob.expects(:perform_async).with(@album.id)

            result = @provider.populate(@album, query: nil)

            assert result.success?
            assert_equal [:ai_description_queued], result.data_populated
          end
        end
      end
    end
  end
end
