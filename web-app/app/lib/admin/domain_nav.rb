module Admin
  module DomainNav
    URL_HELPERS = Rails.application.routes.url_helpers

    FALLBACK_DOMAIN = :music

    ICONS = {
      artist: "M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z",
      album: "M9 19V6l12-3v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zm12-3c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zM9 10l12-3",
      list: "M4 6h16M4 10h16M4 14h16M4 18h16",
      category: "M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z",
      chart: "M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z",
      chat: "M8 10h.01M12 10h.01M16 10h.01M9 16H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-5l-5 5v-5z",
      game: "M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 110 4v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 110-4V7a2 2 0 00-2-2H5z",
      company: "M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4",
      platform: "M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z",
      series: "M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10",
      book: "M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253",
      rankings_album: "M9 7h6m0 10v-3m-3 3h.01M9 17h.01M9 14h.01M12 14h.01M15 11h.01M12 11h.01M9 11h.01M7 21h10a2 2 0 002-2V5a2 2 0 00-2-2H7a2 2 0 00-2 2v14a2 2 0 002 2z",
      rankings_song: "M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-3 7h3m-3 4h3m-6-4h.01M9 16h.01",
      rankings_artist: "M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z"
    }.freeze

    CONFIGS = {
      music: {
        theme: "light",
        stylesheet: "music",
        favicon_dir: "music/favicon",
        title: "The Greatest Music",
        section_label: "Music",
        section_icon: ICONS[:album],
        logo: {type: :image, value: "music/logo.gif"},
        root_path: -> { URL_HELPERS.admin_root_path },
        categories_search_path: -> { URL_HELPERS.search_admin_categories_path },
        items: [
          {label: "Artists", icon: :artist, path: -> { URL_HELPERS.admin_artists_path }},
          {label: "Albums", icon: :album, path: -> { URL_HELPERS.admin_albums_path }},
          {label: "Songs", icon: :album, path: -> { URL_HELPERS.admin_songs_path }},
          {label: "Lists: Albums", icon: :list, path: -> { URL_HELPERS.admin_albums_lists_path }},
          {label: "Lists: Songs", icon: :list, path: -> { URL_HELPERS.admin_songs_lists_path }},
          {label: "Rankings: Album", icon: :rankings_album, path: -> { URL_HELPERS.admin_albums_ranking_configurations_path }},
          {label: "Rankings: Song", icon: :rankings_song, path: -> { URL_HELPERS.admin_songs_ranking_configurations_path }},
          {label: "Rankings: Artist", icon: :rankings_artist, path: -> { URL_HELPERS.admin_artists_ranking_configurations_path }},
          {label: "AI Chats", icon: :chat, path: -> { URL_HELPERS.admin_ai_chats_path }},
          {label: "Categories", icon: :category, path: -> { URL_HELPERS.admin_categories_path }}
        ]
      },
      games: {
        theme: "light",
        stylesheet: "games",
        favicon_dir: nil,
        title: "The Greatest Games",
        section_label: "Games",
        section_icon: ICONS[:game],
        logo: {type: :emoji, value: "🎮"},
        root_path: -> { URL_HELPERS.admin_root_path },
        categories_search_path: -> { URL_HELPERS.search_admin_games_categories_path },
        items: [
          {label: "Games", icon: :game, path: -> { URL_HELPERS.admin_games_games_path }},
          {label: "Companies", icon: :company, path: -> { URL_HELPERS.admin_games_companies_path }},
          {label: "Platforms", icon: :platform, path: -> { URL_HELPERS.admin_games_platforms_path }},
          {label: "Series", icon: :series, path: -> { URL_HELPERS.admin_games_series_index_path }},
          {label: "Categories", icon: :category, path: -> { URL_HELPERS.admin_games_categories_path }},
          {label: "Lists", icon: :list, path: -> { URL_HELPERS.admin_games_lists_path }},
          {label: "Rankings", icon: :chart, path: -> { URL_HELPERS.admin_games_ranking_configurations_path }}
        ]
      },
      books: {
        theme: "cmyk",
        stylesheet: "books",
        favicon_dir: nil,
        title: "The Greatest Books",
        section_label: "Books",
        section_icon: ICONS[:book],
        logo: {type: :emoji, value: "📚"},
        root_path: -> { URL_HELPERS.admin_books_root_path },
        categories_search_path: nil,
        items: [
          {label: "Books", icon: :book, path: -> { URL_HELPERS.admin_books_books_path }},
          {label: "Authors", icon: :artist, path: -> { URL_HELPERS.admin_books_authors_path }}
        ]
      }
    }.freeze

    class << self
      def chrome_for(domain)
        config = CONFIGS[domain&.to_sym] || CONFIGS[FALLBACK_DOMAIN]
        {
          theme: config[:theme],
          stylesheet: config[:stylesheet],
          title: config[:title],
          favicon_dir: config[:favicon_dir]
        }
      end

      def config_for(domain)
        config = CONFIGS[domain&.to_sym]
        return nil if config.nil?

        config.merge(
          root_path: config[:root_path].call,
          categories_search_path: config[:categories_search_path]&.call,
          items: config[:items].map do |item|
            item.merge(path: item[:path].call, icon: ICONS.fetch(item[:icon]))
          end
        )
      end
    end
  end
end
