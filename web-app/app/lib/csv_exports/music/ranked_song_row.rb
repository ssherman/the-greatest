# frozen_string_literal: true

module CsvExports
  module Music
    class RankedSongRow
      URL_HELPERS = Rails.application.routes.url_helpers

      HEADERS = ["Rank", "Score", "ID", "Title", "Artists", "Year", "URL"].freeze

      def self.preloads
        []
      end

      def self.context(song_ids)
        {
          artists: Aggregate.names(::Music::SongArtist.joins(:artist).where(song_id: song_ids),
            group_by: "music_song_artists.song_id", name: "music_artists.name",
            order: "music_song_artists.position NULLS LAST, music_song_artists.id")
        }
      end

      def self.row(ranked_item, ctx)
        song = ranked_item.item
        [
          ranked_item.rank,
          Cells.score(ranked_item.score),
          song.id,
          song.title,
          ctx[:artists][song.id],
          song.release_year,
          "#{Api::Host.base_url(:music)}#{URL_HELPERS.song_path(song)}"
        ]
      end
    end
  end
end
