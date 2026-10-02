# frozen_string_literal: true

require "test_helper"

module CsvExports
  module Music
    class RankedSongRowTest < ActiveSupport::TestCase
      test "headers" do
        assert_equal ["Rank", "Score", "ID", "Title", "Artists", "Year", "URL"], RankedSongRow::HEADERS
      end

      test "a row" do
        ranked = ranked_items(:music_songs_ranked_item)
        song = music_songs(:time)
        ctx = RankedSongRow.context([song.id])

        assert_equal [
          42, "95.50", song.id, "Time", "Pink Floyd", 1973,
          "#{Api::Host.base_url(:music)}/song/time"
        ], RankedSongRow.row(ranked, ctx)
      end
    end
  end
end
