# frozen_string_literal: true

require "test_helper"

module CsvExports
  module Music
    class RankedAlbumRowTest < ActiveSupport::TestCase
      setup do
        @album = music_albums(:dark_side_of_the_moon)
        @ranked = RankedItem.create!(item: @album, ranking_configuration: ranking_configurations(:music_albums_global),
          rank: 1, score: 100)
      end

      test "headers" do
        assert_equal ["Rank", "Score", "ID", "Title", "Artists", "Year", "Genres", "URL"], RankedAlbumRow::HEADERS
      end

      test "a row" do
        ctx = RankedAlbumRow.context([@album.id])

        assert_equal [
          1, "100.00", @album.id, "The Dark Side of the Moon", "Pink Floyd", 1973, "Progressive Rock, Rock",
          "#{Api::Host.base_url(:music)}/album/the-dark-side-of-the-moon"
        ], RankedAlbumRow.row(@ranked, ctx)
      end

      test "no preloads beyond the item" do
        assert_equal [], RankedAlbumRow.preloads
      end

      test "artists are ordered by position, not by insertion" do
        album = music_albums(:abbey_road)
        ::Music::AlbumArtist.create!(album: album, artist: music_artists(:david_gilmour), position: 2)
        ::Music::AlbumArtist.create!(album: album, artist: music_artists(:roger_waters), position: 1)
        ranked = RankedItem.create!(item: album, ranking_configuration: ranking_configurations(:music_albums_global), rank: 2, score: 90)

        row = RankedAlbumRow.row(ranked, RankedAlbumRow.context([album.id]))

        assert_equal "Roger Waters, David Gilmour", row[4]
      end

      test "a soft-deleted genre is left out" do
        ::CategoryItem.create!(category: categories(:music_deleted_genre), item: @album)

        row = RankedAlbumRow.row(@ranked, RankedAlbumRow.context([@album.id]))

        assert_equal "Progressive Rock, Rock", row[6]
      end
    end
  end
end
