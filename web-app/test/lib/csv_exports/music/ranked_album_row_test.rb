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
    end
  end
end
