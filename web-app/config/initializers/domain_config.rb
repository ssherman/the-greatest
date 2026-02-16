# Domain configuration for multi-domain routing
# These can be overridden in environment-specific files

Rails.application.configure do
  config.domains = {
    music: ENV.fetch("MUSIC_DOMAIN", "dev.thegreatestmusic.org"),
    movies: ENV.fetch("MOVIES_DOMAIN", "dev.thegreatestmovies.org"),
    games: ENV.fetch("GAMES_DOMAIN", "dev.thegreatest.games"),
    books: ENV.fetch("BOOKS_DOMAIN", "localhost:3000") # default for development
  }

  # Domain-specific settings
  config.domain_settings = {
    music: {
      name: "The Greatest Music",
      color_scheme: "blue",
      layout: "music/application",
      images_cdn: {
        production: "https://images.thegreatestmusic.org",
        default: "https://images-dev.thegreatestmusic.org"
      }
    },
    movies: {
      name: "The Greatest Movies",
      color_scheme: "red",
      layout: "movies/application",
      images_cdn: {
        production: "https://images.thegreatestmovies.org",
        default: "https://images-dev.thegreatestmovies.org"
      }
    },
    games: {
      name: "The Greatest Games",
      color_scheme: "green",
      layout: "games/application",
      images_cdn: {
        production: "https://images.thegreatest.games",
        default: "https://images-dev.thegreatest.games"
      }
    },
    books: {
      name: "The Greatest Books",
      color_scheme: "purple",
      layout: "application",
      images_cdn: {
        production: "https://images.thegreatestmusic.org",
        default: "https://images-dev.thegreatestmusic.org"
      }
    }
  }
end
