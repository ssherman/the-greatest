# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Album
      module Providers
        class CoverArtTest < ActiveSupport::TestCase
          def setup
            @provider = CoverArt.new
            @artist = music_artists(:pink_floyd)
            @query = ImportQuery.new(artist: @artist, title: "The Wall")
            @album = music_albums(:dark_side_of_the_moon)
          end

          test "populate launches CoverArtDownloadJob and returns success" do
            ::Music::CoverArtDownloadJob.expects(:perform_async).with(@album.id)

            result = @provider.populate(@album, query: @query)

            assert result.success?
            assert_equal [:cover_art_queued], result.data_populated
          end

          test "populate returns failure when album is not persisted" do
            unpersisted_album = ::Music::Album.new(title: "New Album")
            unpersisted_album.album_artists.build(artist: @artist, position: 1)

            result = @provider.populate(unpersisted_album, query: @query)

            refute result.success?
            assert_includes result.errors, "Album must be persisted before queuing cover art download job"
          end

          test "populate works with item-based import when query is nil" do
            ::Music::CoverArtDownloadJob.expects(:perform_async).with(@album.id)

            result = @provider.populate(@album, query: nil)

            assert result.success?
            assert_equal [:cover_art_queued], result.data_populated
          end
        end
      end
    end
  end
end
