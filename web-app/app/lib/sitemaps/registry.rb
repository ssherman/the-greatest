module Sitemaps
  # Which sources each site publishes. Sources are built fresh on every call so
  # tests that stub Thresholds (or the gate) take effect.
  module Registry
    PAGE_SIZE = 50_000

    STATIC_PATHS = {
      books: %w[/ /authors /lists /categories /countries],
      # Books /rankings is deliberately absent: it renders noindex.
      music: %w[/ /albums /songs /artists /lists /albums/lists /songs/lists /rankings],
      games: %w[/ /lists /rankings]
    }.freeze

    def self.page_size = PAGE_SIZE

    # Child files a source spans, at least one. The index advertises exactly
    # this many and the controller serves exactly this many; keep it the only copy.
    def self.page_count(source)
      [(source.count / page_size.to_f).ceil, 1].max
    end

    def self.sources(domain)
      return [] unless STATIC_PATHS.key?(domain)
      return [] if domain == :books && !::Books::PublicIndexing.enabled?

      sources = [StaticPages.new(paths: STATIC_PATHS.fetch(domain))]
      # /news renders noindex without a published post, so a site with none lists nothing.
      news = NewsPosts.new(domain: domain)
      sources << news if news.count > 0
      sources.concat(books_sources) if domain == :books
      sources.concat(music_sources) if domain == :music
      sources.concat(games_sources) if domain == :games
      sources
    end

    def self.books_sources
      [
        RankedItems.new(key: "books", scope: ::Books::Book.catalog,
          ranking_configuration_class: ::Books::RankingConfiguration, path_prefix: "/book/"),
        RankedItems.new(key: "authors", scope: ::Books::Author.catalog,
          ranking_configuration_class: ::Books::Authors::RankingConfiguration, path_prefix: "/author/"),
        RankedLists.new(key: "lists", list_class: ::Books::List,
          ranking_configuration_class: ::Books::RankingConfiguration, path_prefix: "/lists/"),
        Sitemaps::Books::FilterPages.new
      ]
    end
    private_class_method :books_sources

    def self.music_sources
      albums_rc = ::Music::Albums::RankingConfiguration
      songs_rc = ::Music::Songs::RankingConfiguration
      artists_rc = ::Music::Artists::RankingConfiguration
      [
        RankedItems.new(key: "albums", scope: ::Music::Album.all,
          ranking_configuration_class: albums_rc, path_prefix: "/album/"),
        RankedItems.new(key: "songs", scope: ::Music::Song.all,
          ranking_configuration_class: songs_rc, path_prefix: "/song/"),
        RankedItems.new(key: "artists", scope: ::Music::Artist.all,
          ranking_configuration_class: artists_rc, path_prefix: "/artists/"),
        RankedLists.new(key: "album_lists", list_class: ::Music::Albums::List,
          ranking_configuration_class: albums_rc, path_prefix: "/albums/lists/"),
        RankedLists.new(key: "song_lists", list_class: ::Music::Songs::List,
          ranking_configuration_class: songs_rc, path_prefix: "/songs/lists/"),
        # /categories/:slug shows ranked artists plus ranked albums.
        RankedCategories.new(key: "categories", scope: ::Music::Category.active, path_prefix: "/categories/",
          counts: -> {
            ranked_category_counts(::Music::Artist, artists_rc)
              .merge(ranked_category_counts(::Music::Album, albums_rc)) { |_id, a, b| a + b }
          }),
        RankedCategories.new(key: "album_categories", scope: ::Music::Category.active, path_prefix: "/albums/categories/",
          counts: -> { ranked_category_counts(::Music::Album, albums_rc) })
      ]
    end
    private_class_method :music_sources

    def self.games_sources
      games_rc = ::Games::RankingConfiguration
      [
        RankedItems.new(key: "games", scope: ::Games::Game.all,
          ranking_configuration_class: games_rc, path_prefix: "/game/"),
        RankedLists.new(key: "lists", list_class: ::Games::List,
          ranking_configuration_class: games_rc, path_prefix: "/lists/"),
        # /categories/:slug shows the ranked games in the category.
        RankedCategories.new(key: "categories", scope: ::Games::Category.active, path_prefix: "/categories/",
          counts: -> { ranked_category_counts(::Games::Game, games_rc) })
      ]
    end
    private_class_method :games_sources

    # {category_id => ranked items of item_class in the primary RC}. The same
    # join the category controllers use, plus rank IS NOT NULL.
    def self.ranked_category_counts(item_class, ranking_configuration_class)
      rc = ranking_configuration_class.default_primary
      return {} unless rc

      ::CategoryItem
        .where(item_type: item_class.name)
        .joins("JOIN ranked_items ON ranked_items.item_id = category_items.item_id AND ranked_items.item_type = category_items.item_type")
        .where(ranked_items: {ranking_configuration_id: rc.id})
        .where.not(ranked_items: {rank: nil})
        .group(:category_id)
        .count
    end
    private_class_method :ranked_category_counts

    def self.find(domain, key)
      sources(domain).find { |source| source.key == key }
    end
  end
end
