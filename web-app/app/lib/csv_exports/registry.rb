# frozen_string_literal: true

# Everything the CSV export feature needs to know about a ranking domain, in
# one place (spec §7). A configuration type with no entry is not exportable:
# RequestGenerate returns :not_exportable, the nightly job skips it, the admin
# card does not render. That is what keeps the creator rankings (authors,
# artists) and movies out without a conditional anywhere else.
#
# Row classes are named as strings and constantized on use so this file loads
# before the row classes without a dependency cycle.
module CsvExports
  module Registry
    Entry = Struct.new(
      :ranking_configuration_class, # "Books::RankingConfiguration"
      :row_class_name,              # "CsvExports::Books::RankedBookRow"
      :slug,                        # filename token
      :noun,                        # "top 500 <noun>" in the modal
      :relation,                    # ->(config) { the full, unfiltered ranked relation in rank order }
      keyword_init: true
    ) do
      def row_class
        row_class_name.constantize
      end
    end

    # Music and games mirror their index actions' joins so the year filter
    # service (which addresses the media table by name) can be applied on top.
    # Unranked rows (rank NULL) are excluded everywhere: a rankings CSV with an
    # empty Rank cell is noise, and the books query already excludes them.
    ENTRIES = [
      Entry.new(
        ranking_configuration_class: "Books::RankingConfiguration",
        row_class_name: "CsvExports::Books::RankedBookRow",
        slug: "books",
        noun: "books",
        relation: ->(config) { ::Books::RankedBooksQuery.call(ranking_configuration: config) }
      ),
      Entry.new(
        ranking_configuration_class: "Music::Albums::RankingConfiguration",
        row_class_name: "CsvExports::Music::RankedAlbumRow",
        slug: "albums",
        noun: "albums",
        relation: ->(config) {
          config.ranked_items
            .joins("JOIN music_albums ON ranked_items.item_id = music_albums.id AND ranked_items.item_type = 'Music::Album'")
            .where(item_type: "Music::Album").where.not(rank: nil).order(:rank)
        }
      ),
      Entry.new(
        ranking_configuration_class: "Music::Songs::RankingConfiguration",
        row_class_name: "CsvExports::Music::RankedSongRow",
        slug: "songs",
        noun: "songs",
        relation: ->(config) {
          config.ranked_items
            .joins("JOIN music_songs ON ranked_items.item_id = music_songs.id AND ranked_items.item_type = 'Music::Song'")
            .where(item_type: "Music::Song").where.not(rank: nil).order(:rank)
        }
      ),
      Entry.new(
        ranking_configuration_class: "Games::RankingConfiguration",
        row_class_name: "CsvExports::Games::RankedGameRow",
        slug: "games",
        noun: "games",
        relation: ->(config) {
          config.ranked_items
            .joins("JOIN games_games ON ranked_items.item_id = games_games.id AND ranked_items.item_type = 'Games::Game'")
            .where(item_type: "Games::Game").where.not(rank: nil).order(:rank)
        }
      )
    ].freeze

    def self.for_config(config)
      ENTRIES.find { |entry| entry.ranking_configuration_class == config.type }
    end

    def self.exportable?(config)
      for_config(config).present?
    end

    # "the-greatest-books-rankings-2026-09-18.csv" for a global configuration;
    # a user-owned one is named after itself (capped so a long name cannot push
    # the filename past the 255-byte filesystem limit).
    def self.filename_for(config, date: Date.current)
      entry = for_config(config) or raise ArgumentError, "#{config.type} is not exportable"
      base = if config.global?
        "the-greatest-#{entry.slug}-rankings"
      else
        "#{config.name.parameterize.truncate(80, omission: "").presence || "rankings"}-#{entry.slug}"
      end
      "#{base}-#{date.iso8601}.csv"
    end
  end
end
