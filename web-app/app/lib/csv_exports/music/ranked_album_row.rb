# frozen_string_literal: true

module CsvExports
  module Music
    class RankedAlbumRow
      URL_HELPERS = Rails.application.routes.url_helpers

      HEADERS = ["Rank", "Score", "ID", "Title", "Artists", "Year", "Genres", "URL"].freeze

      def self.preloads
        []
      end

      def self.context(album_ids)
        {
          # position is defaulted and validated on the join model; NULLS LAST is belt-and-braces for raw inserts.
          artists: Aggregate.names(::Music::AlbumArtist.joins(:artist).where(album_id: album_ids),
            group_by: "music_album_artists.album_id", name: "music_artists.name",
            order: "music_album_artists.position NULLS LAST, music_album_artists.id"),
          genres: Aggregate.names(
            ::CategoryItem.joins(:category).where(item_type: "Music::Album", item_id: album_ids,
              categories: {type: "Music::Category", deleted: false, category_type: ::Category.category_types[:genre]}),
            group_by: "category_items.item_id", name: "categories.name", order: "categories.name"
          )
        }
      end

      def self.row(ranked_item, ctx)
        album = ranked_item.item
        [
          ranked_item.rank,
          Cells.score(ranked_item.score),
          album.id,
          album.title,
          ctx[:artists][album.id],
          album.release_year,
          ctx[:genres][album.id],
          "#{Api::Host.base_url(:music)}#{URL_HELPERS.album_path(album)}"
        ]
      end
    end
  end
end
