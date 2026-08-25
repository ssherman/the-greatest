Rails.application.routes.draw do
  # rails_icons preview UI is only useful in development
  mount RailsIcons::Engine, at: "/rails_icons" if Rails.env.development?

  # Music domain routes (scoped within domain constraint)
  constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
    # All music routes are prefixed with 'music_' for route helpers to avoid
    # conflicts when other domains (games, movies) add similar resources
    scope as: "music" do
      # Lists overview and public submission
      resources :lists, only: [:index, :new, :create], controller: "music/lists"

      # Search
      get "search", to: "music/searches#index"
    end

    # Artist rankings (outside rc scope - always uses default primary configs for both albums and songs)
    get "artists", to: "music/artists/ranked_items#index", as: :artists
    get "artists/page/:page", to: "music/artists/ranked_items#index", as: :artists_page, constraints: {page: /\d+/}

    # Category pages (outside rc scope - always uses default primary configs for both artists and albums)
    get "categories/:id", to: "music/categories#show", as: :music_category

    # DELIBERATELY OUTSIDE the (/rc/:ranking_configuration_id) scope below -- see
    # the books block for the full reasoning. The short version: these pages are
    # edge-cached for a day, they show record fields rather than rankings, and an
    # unconstrained optional path segment in front of a cached page is an
    # unbounded supply of distinct cache keys, every one of them a MISS that
    # renders at origin. That is the flood that took the legacy page down.
    #
    # correctable_type comes from route defaults, never from a param: #new then
    # has no user input to validate at all. Same shared controller as books and
    # games.
    get "album/:slug/suggest-correction", to: "corrections#new",
      defaults: {correctable_type: "Music::Album"}, as: :music_album_correction,
      constraints: {format: /html/}

    # Same cacheable-GET shape as the form above, nested under the same
    # /suggest-correction prefix so robots.txt's existing
    # "Disallow: /*/suggest-correction" rule (unanchored, so it matches this
    # path too) covers it without a second rule.
    get "album/:slug/suggest-correction/thanks", to: "corrections#thanks",
      defaults: {correctable_type: "Music::Album"}, as: :music_album_correction_thanks,
      constraints: {format: /html/}

    # All music routes with optional ranking configuration parameter
    scope "(/rc/:ranking_configuration_id)" do
      # Album routes
      get "albums", to: "music/albums/ranked_items#index", as: :albums
      get "albums/page/:page", to: "music/albums/ranked_items#index", as: :albums_page, constraints: {page: /\d+/}
      get "albums/lists", to: "music/albums/lists#index", as: :music_albums_lists
      get "albums/lists/page/:page", to: "music/albums/lists#index", as: :music_albums_lists_page, constraints: {page: /\d+/}
      get "albums/lists/:id", to: "music/albums/lists#show", as: :music_album_list
      get "albums/lists/:id/page/:page", to: "music/albums/lists#show", as: :music_album_list_page, constraints: {page: /\d+/}
      get "albums/categories/:id", to: "music/albums/categories#show", as: :music_album_category
      get "albums/categories/:id/page/:page", to: "music/albums/categories#show", as: :music_album_category_page, constraints: {page: /\d+/}
      # Year-filtered albums (must come before :id to avoid treating "1990s" as a slug)
      get "albums/since/:year", to: "music/albums/ranked_items#index", as: :albums_since_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "since"}
      get "albums/since/:year/page/:page", to: "music/albums/ranked_items#index", as: :albums_since_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "since"}
      get "albums/through/:year", to: "music/albums/ranked_items#index", as: :albums_through_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "through"}
      get "albums/through/:year/page/:page", to: "music/albums/ranked_items#index", as: :albums_through_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "through"}
      get "albums/:year", to: "music/albums/ranked_items#index", as: :albums_by_year,
        constraints: {year: /\d{4}(s|-\d{4})?/}
      get "albums/:year/page/:page", to: "music/albums/ranked_items#index", as: :albums_by_year_page,
        constraints: {year: /\d{4}(s|-\d{4})?/, page: /\d+/}
      get "album/:slug", to: "music/albums#show", as: :album

      # Song routes
      get "songs", to: "music/songs/ranked_items#index", as: :songs
      get "songs/page/:page", to: "music/songs/ranked_items#index", as: :songs_page, constraints: {page: /\d+/}
      get "songs/lists", to: "music/songs/lists#index", as: :music_songs_lists
      get "songs/lists/page/:page", to: "music/songs/lists#index", as: :music_songs_lists_page, constraints: {page: /\d+/}
      get "songs/lists/:id", to: "music/songs/lists#show", as: :music_song_list
      get "songs/lists/:id/page/:page", to: "music/songs/lists#show", as: :music_song_list_page, constraints: {page: /\d+/}
      # Year-filtered songs (must come before :id to avoid treating "1990s" as a slug)
      get "songs/since/:year", to: "music/songs/ranked_items#index", as: :songs_since_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "since"}
      get "songs/since/:year/page/:page", to: "music/songs/ranked_items#index", as: :songs_since_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "since"}
      get "songs/through/:year", to: "music/songs/ranked_items#index", as: :songs_through_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "through"}
      get "songs/through/:year/page/:page", to: "music/songs/ranked_items#index", as: :songs_through_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "through"}
      get "songs/:year", to: "music/songs/ranked_items#index", as: :songs_by_year,
        constraints: {year: /\d{4}(s|-\d{4})?/}
      get "songs/:year/page/:page", to: "music/songs/ranked_items#index", as: :songs_by_year_page,
        constraints: {year: /\d{4}(s|-\d{4})?/, page: /\d+/}
      get "song/:slug", to: "music/songs#show", as: :song

      # Artist routes
      get "artists/categories/:id", to: "music/artists/categories#show", as: :music_artist_category
      get "artists/categories/:id/page/:page", to: "music/artists/categories#show", as: :music_artist_category_page, constraints: {page: /\d+/}
      get "artists/:id", to: "music/artists#show", as: :artist
    end

    # Admin interface for music domain
    namespace :admin, module: "admin/music" do
      root to: "dashboard#index"

      resources :news_topics
      resources :news_posts do
        collection do
          post :preview
        end
      end

      # MusicBrainz search endpoints (shared across admin features)
      scope :musicbrainz, controller: "musicbrainz_search", as: "musicbrainz" do
        get :artists
      end

      # Ranking configuration routes must come BEFORE the resource routes
      # to prevent friendly_id from treating "ranking_configurations" as a slug
      namespace :artists do
        resources :ranking_configurations do
          member do
            post :execute_action
          end
          collection do
            post :index_action
          end
        end
      end

      namespace :albums do
        resources :ranking_configurations do
          member do
            post :execute_action
          end
          collection do
            post :index_action
          end
        end

        resources :lists do
          resource :wizard, only: [:show], controller: "list_wizard" do
            get "step/:step", action: :show_step, as: :step
            get "step/:step/status", action: :step_status, as: :step_status
            post "step/:step/advance", action: :advance_step, as: :advance_step
            post "step/:step/back", action: :back_step, as: :back_step
            post "save_html", action: :save_html, as: :save_html
            post "reparse", action: :reparse, as: :reparse
            post "restart", action: :restart
            get "musicbrainz_release_search", to: "list_items_actions#musicbrainz_release_search", as: :musicbrainz_release_search
          end

          resources :items, controller: "list_items_actions", only: [] do
            member do
              get "modal/:modal_type", action: :modal, as: :modal
              post :verify
              post :skip
              patch :metadata
              post :re_enrich
              post :manual_link
              post :link_musicbrainz_release
              post :link_musicbrainz_artist
              post :link_musicbrainz_url
              post :queue_import
              delete :destroy
            end

            collection do
              post :bulk_verify
              post :bulk_skip
              delete :bulk_delete
            end
          end
        end
      end

      namespace :songs do
        resources :ranking_configurations do
          member do
            post :execute_action
          end
          collection do
            post :index_action
          end
        end

        resources :lists do
          resource :wizard, only: [:show], controller: "list_wizard" do
            get "step/:step", action: :show_step, as: :step
            get "step/:step/status", action: :step_status, as: :step_status
            post "step/:step/advance", action: :advance_step, as: :advance_step
            post "step/:step/back", action: :back_step, as: :back_step
            post "save_html", action: :save_html, as: :save_html
            post "reparse", action: :reparse, as: :reparse
            post "restart", action: :restart
            get "musicbrainz_recording_search", to: "list_items_actions#musicbrainz_recording_search", as: :musicbrainz_recording_search
          end

          resources :items, controller: "list_items_actions", only: [] do
            member do
              get "modal/:modal_type", action: :modal, as: :modal
              post :verify
              post :skip
              patch :metadata
              post :re_enrich
              post :manual_link
              post :link_musicbrainz_recording
              post :link_musicbrainz_artist
              post :link_musicbrainz_url
              post :queue_import
              delete :destroy
            end

            collection do
              post :bulk_verify
              post :bulk_skip
              delete :bulk_delete
            end
          end
        end
      end

      resources :artists do
        resources :album_artists, only: [:create], shallow: true
        resources :song_artists, only: [:create], shallow: true
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        member do
          post :execute_action
        end
        collection do
          post :import_from_musicbrainz
          post :bulk_action
          post :index_action
          get :search
        end
      end

      resources :albums do
        resources :album_artists, only: [:create], shallow: true
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        member do
          post :execute_action
        end
        collection do
          post :bulk_action
          get :search
        end
      end

      resources :album_artists, only: [:update, :destroy]

      resources :songs do
        resources :song_artists, only: [:create], shallow: true
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        member do
          post :execute_action
        end
        collection do
          post :bulk_action
          get :search
        end
      end

      resources :song_artists, only: [:update, :destroy]

      resources :ai_chats, only: [:index, :show]

      resources :categories do
        collection do
          get :search
        end
      end

      # Shared controller, routed per domain -- same shape as descriptions and
      # category items. The domain comes from the route, so the index can scope to
      # this domain's correctable types.
      resources :corrections, only: [:index, :show], controller: "/admin/corrections" do
        member do
          post :apply
          post :reject
          post :resolve
        end
        collection do
          post :bulk_reject
        end
      end
    end
  end
  require "sidekiq/web"
  require "sidekiq/cron/web"

  Sidekiq::Web.use(Rack::Auth::Basic) do |username, password|
    ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(username), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_ADMIN_USERNAME"].to_s)) &
      ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(password), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_ADMIN_PASSWORD"].to_s))
  end
  mount Sidekiq::Web => "/sidekiq-admin"

  post "auth/sign_in"
  post "auth/sign_out"
  post "auth/check_provider"

  # Stripe webhooks. Deliberately outside every domain constraint: Stripe posts to
  # one URL and the host is whatever the endpoint was registered with.
  post "webhooks/stripe", to: "webhooks/stripe#create"

  # User-list endpoints — global (non-domain-constrained), JSON-only.
  # The state endpoint is scoped to Current.domain via the controller.
  get "user_list_state", to: "user_list_state#show", as: :user_list_state

  # Per-item review state — global (non-domain-constrained), JSON-only, never cached.
  get "review_state", to: "review_state#show", as: :review_state

  # Uncached, no database query. Exists so the edge-cached correction form can get
  # a token that belongs to the caller's session rather than to whoever populated
  # the cache.
  get "correction_token", to: "correction_token#show", as: :correction_token
  resources :corrections, only: [:create]

  # Review writes — global (non-domain-constrained), Turbo Stream, never cached.
  post "reviews", to: "reviews#create", as: :reviews
  patch "reviews/:id", to: "reviews#update", as: :review
  delete "reviews/:id", to: "reviews#destroy"
  post "user_lists", to: "user_lists#create", as: :user_lists
  post "user_lists/:user_list_id/items",
    to: "user_list_items#create",
    as: :user_list_items
  delete "user_lists/:user_list_id/items/:id",
    to: "user_list_items#destroy",
    as: :user_list_item

  # Type-scoped typeahead for the "add item from list page" search box (02e).
  # Signed-in, never cached; scoped by listable_type (e.g. Music::Album).
  get "listable_search", to: "listable_searches#index", as: :listable_search

  # My Lists read surface (Phase A) — global, never cached, per-domain layout
  # resolved from Current.domain in the controller. index is owner-only; show
  # serves HTML + CSV to the owner or any viewer when the list is public (404s
  # otherwise via UserList.visible_to).
  get "my/lists", to: "my_lists#index", as: :my_lists
  get "my/lists/:id", to: "my_lists#show", as: :my_list
  get "my/lists/:id/page/:page", to: "my_lists#show", as: :my_list_page, constraints: {page: /\d+/}

  # My Reviews (personal ratings library) -- global, never cached, per-domain
  # layout resolved from Current.domain in the controller. 404s on a domain with
  # no reviewable types (Reviews::Registry) rather than rendering an empty page.
  get "my/reviews", to: "my_reviews#index", as: :my_reviews
  get "my/reviews/page/:page", to: "my_reviews#index", as: :my_reviews_page, constraints: {page: /\d+/}

  # Membership -- global (non-domain-constrained) like /my/lists and /searches:
  # one membership covers every site, so there is one set of URLs served on
  # every host, with the layout resolved from Current.domain in the controller.
  get "membership", to: "membership#show", as: :membership
  get "membership/thanks", to: "membership#thanks", as: :membership_thanks
  post "membership/checkout", to: "membership#checkout", as: :membership_checkout
  post "membership/donate", to: "membership#donate", as: :membership_donate
  post "membership/portal", to: "membership#portal", as: :membership_portal

  # Per-user membership state for edge-cached pages, following
  # UserListStateController: never cached, JSON only.
  get "membership_state", to: "membership_state#show", as: :membership_state

  # The members' area -- the first thing behind the paywall.
  get "members", to: "members#show", as: :members

  # News -- like /membership and /my/lists, one controller and one set of
  # views serve every site, with the layout resolved from Current.domain in
  # the controller. Unlike those, the routes ARE domain-constrained: the
  # feature is only built for books, music and games, and without this
  # constraint the global routes also matched on the movies host, serving an
  # edge-cached, indexable page for a site that is otherwise just a
  # placeholder root. DomainConstraint#initialize splits on "," and each
  # config.domains value may itself be a comma-separated list, so joining the
  # three with "," composes correctly.
  #
  # The topic route is declared BEFORE the slug route, and "topic" is a
  # friendly_id reserved word, so no post can ever claim /news/topic.
  #
  # Order matters: /page/1 must precede the generic /page/:page.
  #
  # Every route declares the formats it serves. Only the bare index has an rss
  # representation; the paginated and topic-filtered paths share #index, so
  # without their own constraint /news/page/2.rss and /news/topic/x.rss would
  # each serve the WHOLE feed from a scoped URL -- an edge-cached page whose
  # contents contradict its path. Measured before constraining: an
  # unrepresentable format was a 406, and becomes a 404 once the route stops
  # matching. No news slug contains a dot (checked against all 31 live rows),
  # so no real URL loses its trailing segment to the format parser.
  constraints DomainConstraint.new(
    [:books, :music, :games].map { |domain| Rails.application.config.domains[domain] }.join(",")
  ) do
    get "news", to: "news_posts#index", as: :news, defaults: {format: :html},
      constraints: {format: /html|rss/}
    get "news/page/1", to: redirect("/news", status: 301)
    get "news/page/:page", to: "news_posts#index", as: :news_page,
      constraints: {page: /[1-9]\d*/, format: /html/}
    get "news/topic/:topic_slug/page/1", to: redirect("/news/topic/%{topic_slug}", status: 301)
    get "news/topic/:topic_slug", to: "news_posts#index", as: :news_topic, constraints: {format: /html/}
    get "news/topic/:topic_slug/page/:page", to: "news_posts#index", as: :news_topic_page,
      constraints: {page: /[1-9]\d*/, format: /html/}
    get "news/:slug", to: "news_posts#show", as: :news_post, constraints: {format: /html/}
  end

  # Legacy books URL. ~15 years of inbound links point at /support.
  get "support", to: redirect("/membership", status: 301)

  # Compatibility alias: the books site (and earlier Greatest sites) link to a
  # user list at /user_lists/:id. Point it at the same show action — owner or
  # any viewer when the list is public, per UserList.visible_to — so those URLs
  # keep working once books migrates onto this app. (The POST create and nested
  # item routes below are distinct verbs/paths and don't conflict.)
  # The legacy site's index/new/edit have no equivalent here — the write surface
  # is Phase B (user-lists-02f) — so they land on the read pages. `new` must be
  # declared before `:id` or the wildcard swallows it.
  get "user_lists", to: redirect("/my/lists", status: 301)
  get "user_lists/new", to: redirect("/my/lists", status: 301)
  get "user_lists/:id/edit", to: redirect("/my/lists/%{id}", status: 301), constraints: {id: /\d+/}
  get "user_lists/:id", to: "my_lists#show", as: :user_list
  get "user_lists/:id/page/:page", to: "my_lists#show", as: :user_list_page, constraints: {page: /\d+/}

  # Legacy review URLs from the books site. GET "reviews" does not collide with
  # the POST "reviews" create route above -- different verbs.
  get "reviews", to: redirect("/my/reviews", status: 301)
  get "reviews/account_required", to: redirect("/my/reviews", status: 301)

  # Saved searches -- global, never cached, per-domain layout resolved from
  # Current.domain in the controller. index is owner-only; show serves the
  # owner or any viewer when the search is public (404s otherwise via
  # SavedSearch.visible_to). The write actions are increment 6: a route
  # pointing at an action that does not exist yet is a 500, not a 404, and
  # `searches/new` falls through to a clean 404 while :id stays \d+-constrained.
  get "searches", to: "saved_searches#index", as: :saved_searches
  get "searches/page/1", to: redirect("/searches", status: 301)
  get "searches/page/:page", to: "saved_searches#index", as: :saved_searches_page,
    constraints: {page: /\d+/}

  # Write surface (increment 6). `new` is declared before `:id` deliberately:
  # Rails tries routes in declaration order, and the day `:id` is loosened to
  # admit a slug, a `searches/:id` above this would swallow GET /searches/new.
  get "searches/new", to: "saved_searches#new", as: :new_saved_search
  # The saved-search form's taxonomy pickers (JSON only). Declared alongside
  # `searches/new`, above `searches/:id`: declaration order is what keeps a
  # future-loosened :id constraint from swallowing these paths, same as new.
  get "searches/categories", to: "saved_searches/categories#index", as: :saved_search_categories
  get "searches/languages", to: "saved_searches/languages#index", as: :saved_search_languages
  get "searches/countries", to: "saved_searches/countries#index", as: :saved_search_countries
  post "searches", to: "saved_searches#create"
  get "searches/:id/edit", to: "saved_searches#edit", as: :edit_saved_search,
    constraints: {id: /\d+/}
  patch "searches/:id", to: "saved_searches#update", constraints: {id: /\d+/}
  put "searches/:id", to: "saved_searches#update", constraints: {id: /\d+/}
  delete "searches/:id", to: "saved_searches#destroy", constraints: {id: /\d+/}

  # show serves the owner or any viewer when the search is public, including
  # anonymous, and 404s everything else via SavedSearch.visible_to.
  get "searches/:id", to: "saved_searches#show", as: :saved_search,
    constraints: {id: /\d+/}
  get "searches/:id/page/1", to: redirect("/searches/%{id}", status: 301),
    constraints: {id: /\d+/}
  get "searches/:id/page/:page", to: "saved_searches#show", as: :saved_search_page,
    constraints: {id: /\d+/, page: /\d+/}

  # Legacy `scope "(/v/:view_type)" { resources :searches }`. These 301 rather
  # than rendering: increment 5 dropped the view switcher, so grid, table and
  # the bare path all resolve to the same card grid and a redirect costs the
  # reader nothing while saving two duplicate URLs and two code paths. The page
  # number carries through -- an approximation either way, since legacy's grid
  # and table paged at 120 and this pages at 50.
  get "v/:view_type/searches", to: redirect("/searches", status: 301),
    constraints: {view_type: /grid|table/}
  get "v/:view_type/searches/:id", to: redirect("/searches/%{id}", status: 301),
    constraints: {view_type: /grid|table/, id: /\d+/}
  get "v/:view_type/searches/:id/page/:page",
    to: redirect("/searches/%{id}/page/%{page}", status: 301),
    constraints: {view_type: /grid|table/, id: /\d+/, page: /\d+/}

  # Domain-specific roots using Default controllers
  constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
    get "rankings", to: "music/default#rankings", as: :music_rankings
    root to: "music/default#index", as: :music_root
  end

  constraints DomainConstraint.new(Rails.application.config.domains[:movies]) do
    root to: "movies/default#index", as: :movies_root
  end

  constraints DomainConstraint.new(Rails.application.config.domains[:books]) do
    # Admin interface for books domain
    namespace :admin, module: "admin/books", as: "admin_books" do
      root to: "dashboard#index"

      resources :books do
        resources :editions, shallow: true do
          member do
            post :set_default
          end
          resources :images, only: [:index, :create], controller: "/admin/images"
          resources :credits, only: [:create]
        end
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        resources :book_authors, only: [:create]
        resources :book_relationships, only: [:create]
        resources :credits, only: [:create]
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        collection do
          get :search
        end
      end

      resources :book_authors, only: [:update, :destroy]
      resources :book_relationships, only: [:update, :destroy]
      resources :credits, only: [:update, :destroy]
      resources :author_relationships, only: [:update, :destroy]
      resources :authors do
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        resources :author_relationships, only: [:create]
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        member do
          post :execute_action
        end
        collection do
          get :search
        end
      end

      resources :series do
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        resources :series_books, only: [:create]
      end
      resources :series_books, only: [:update, :destroy] do
        member do
          post :make_representative
        end
      end

      resources :categories do
        collection do
          get :search
        end
      end

      resources :lists

      resources :reviews, only: [:index, :show, :destroy]

      # Shared controller, routed per domain -- same shape as descriptions and
      # category items. The domain comes from the route, so the index can scope to
      # this domain's correctable types.
      resources :corrections, only: [:index, :show], controller: "/admin/corrections" do
        member do
          post :apply
          post :reject
          post :resolve
        end
        collection do
          post :bulk_reject
        end
      end

      resources :news_topics
      resources :news_posts do
        collection do
          post :preview
        end
      end

      resources :ranking_configurations do
        member { post :execute_action }
        collection { post :index_action }
      end
    end

    scope "(/rc/:ranking_configuration_id)" do
      get "book/:slug", to: "books/books#show", as: :book
    end

    # NOT inside the (/rc/:ranking_configuration_id) scope above, and that is the
    # single most load-bearing decision in the corrections routing.
    #
    # These two pages are edge-cached for 24 hours, which is the whole reason this
    # feature exists: the legacy correction page was uncached and a flood of GETs
    # took the production site down. But CorrectionsController never calls
    # load_ranking_configuration -- it has no use for one, it renders record
    # fields, not rankings -- so an rc-prefixed URL would render 200 for ANY value
    # of the segment. Every distinct value is a distinct Cloudflare cache key,
    # every one a MISS, every one a full render at origin: the legacy flood
    # reproduced with one extra path segment, and a Cache Rule that normalises
    # query strings cannot see a path segment at all.
    #
    # Leaving the scope off means /rc/<anything>/book/:slug/suggest-correction
    # matches no route and is rejected by the router before a controller, a view
    # or a database connection is involved. Constraining the segment to /\d+/
    # would NOT be equivalent -- there are unbounded distinct integers.
    #
    # constraints: {format: /html/} closes the same axis on (.:format): .json,
    # .foo and so on are each another cache key. Same precedent as the news
    # routes above.
    #
    # correctable_type comes from route defaults, never from a param: #new then has
    # no user input to validate at all. Music and games each add one analogous line
    # pointing at this same shared controller.
    get "book/:slug/suggest-correction", to: "corrections#new",
      defaults: {correctable_type: "Books::Book"}, as: :books_book_correction,
      constraints: {format: /html/}

    # Same cacheable-GET shape as the form above, nested under the same
    # /suggest-correction prefix so robots.txt's existing
    # "Disallow: /*/suggest-correction" rule (unanchored, so it matches this
    # path too) covers it without a second rule.
    get "book/:slug/suggest-correction/thanks", to: "corrections#thanks",
      defaults: {correctable_type: "Books::Book"}, as: :books_book_correction_thanks,
      constraints: {format: /html/}

    scope "(/rc/:ranking_configuration_id)" do
      get "author/:slug", to: "books/authors#show", as: :author
      get "author/:slug/all-books", to: "books/authors#all_books", as: :author_all_books
      get "author/:slug/all-books/page/:page", to: "books/authors#all_books",
        constraints: {page: /\d+/}
    end

    # Legacy 301s. /books/:id is the legacy CANONICAL book url (~156k indexed);
    # /items/:id is its older alias. Legacy rc ids are meaningless here, so the
    # rc segment is matched and discarded.
    scope "(/rc/:ranking_configuration_id)" do
      get "books/:id", to: "books/legacy_books#show", constraints: {id: /\d+/}
    end
    get "items/:id", to: "books/legacy_books#show", constraints: {id: /\d+/}

    get "lists/sorted-by/created_at(/page/:page)", to: redirect("/lists?sort=newest", status: 301)
    get "lists/sorted-by/:sort(/page/:page)", to: redirect("/lists", status: 301)
    get "lists/search_results", to: redirect("/lists", status: 301)
    get "lists/condensed", to: redirect("/lists", status: 301)
    get "lists/help", to: redirect("/lists", status: 301)
    get "lists/pending_lists", to: redirect("/lists", status: 301)
    get "lists/specialized_edit", to: redirect("/lists", status: 301)
    get "v/:view_type/lists", to: redirect("/lists", status: 301)
    get "v/:view_type/lists/page/:page", to: redirect("/lists", status: 301), constraints: {page: /\d+/}
    get "v/:view_type/lists/:id", to: redirect("/lists/%{id}", status: 301), constraints: {id: /\d+/}
    get "v/:view_type/lists/:id/page/:page", to: redirect("/lists/%{id}", status: 301),
      constraints: {id: /\d+/, page: /\d+/}

    get "lists/page/1", to: redirect("/lists", status: 301)
    get "lists/:id/page/1", to: redirect("/lists/%{id}", status: 301), constraints: {id: /\d+/}

    # Legacy blog URLs. /news is the legacy index path already and carries over
    # unchanged, so it is deliberately absent here.
    get "blog_posts", to: redirect("/news", status: 301)
    get "blog_posts/:slug", to: redirect("/news/%{slug}", status: 301)

    get "authors/page/1", to: redirect("/authors", status: 301)
    get "authors", to: "books/authors/ranked_items#index", as: :books_authors
    get "authors/page/:page", to: "books/authors/ranked_items#index",
      as: :books_authors_page, constraints: {page: /\d+/}

    get "authors/view/:view(/page/:page)", to: redirect("/authors", status: 301)
    get "authors/:id/all_books", to: "books/legacy_authors#show", constraints: {id: /\d+/}
    get "authors/:id", to: "books/legacy_authors#show", constraints: {id: /\d+/}

    # Site search. Declared above the legacy collection catch-alls further down
    # so a future collection slug cannot swallow it.
    get "search", to: "books/searches#index", as: :books_search

    get "lists", to: "books/lists#index", as: :books_lists
    get "lists/page/:page", to: "books/lists#index", as: :books_lists_page, constraints: {page: /\d+/}
    get "lists/:id", to: "books/lists#show", as: :books_list, constraints: {id: /\d+/}
    get "lists/:id/page/:page", to: "books/lists#show", as: :books_list_page,
      constraints: {id: /\d+/, page: /\d+/}

    get "rc/:ranking_configuration_id/lists/page/1", to: redirect("/lists", status: 301)
    get "rc/:ranking_configuration_id/lists/:id/page/1", to: redirect("/lists/%{id}", status: 301),
      constraints: {id: /\d+/}

    get "rc/:ranking_configuration_id/lists", to: "books/lists#index", as: :books_rc_lists
    get "rc/:ranking_configuration_id/lists/page/:page", to: "books/lists#index",
      as: :books_rc_lists_page, constraints: {page: /\d+/}
    get "rc/:ranking_configuration_id/lists/:id", to: "books/lists#show", as: :books_rc_list,
      constraints: {id: /\d+/}
    get "rc/:ranking_configuration_id/lists/:id/page/:page", to: "books/lists#show",
      as: :books_rc_list_page, constraints: {id: /\d+/, page: /\d+/}

    # Ranked index. Root is canonical; pagination is path-based.
    # Order matters: /page/1 must precede the generic /page/:page.
    root to: "books/ranked_items#index", as: :books_root
    get "page/1", to: redirect("/", status: 301)
    get "page/:page", to: "books/ranked_items#index", as: :books_page, constraints: {page: /\d+/}
    get "the-greatest-books", to: redirect("/", status: 301)
    get "rc/:ranking_configuration_id", to: "books/ranked_items#index", as: :books_rc
    get "rc/:ranking_configuration_id/page/:page", to: "books/ranked_items#index",
      as: :books_rc_page, constraints: {page: /\d+/}

    # #show is the modal's Apply endpoint: it 303s to the canonical filter path
    # so the URL grammar lives only in Books::FilterPath. #categories and
    # #countries each render one drill-down pane. None of these are ever
    # linked publicly.
    get "filters", to: "books/filters#show", as: :books_filters
    get "filters/categories", to: "books/filters#categories", as: :books_filters_categories
    get "filters/countries", to: "books/filters#countries", as: :books_filters_countries

    # The Global Canon. Settings live in the PATH, never a query string, so each
    # variant is its own Cloudflare edge-cache entry.
    #
    # The segment constraints are LOAD-BEARING for the same reason collection_re
    # is: an unconstrained segment mints an unbounded space of soft-duplicates of
    # a page that ranks. Anchors (\A, \z) raise ArgumentError in a segment
    # constraint -- Rails anchors them itself.
    #
    # canon_pct admits any integer 0..100 even though the menu offers only
    # multiples of five, so a hand-typed or bookmarked value still resolves.
    #
    # `settings` is declared FIRST: the day a shorter canon shape is added, a
    # route above this one could otherwise swallow it.
    canon_total = /(?:50|100|150|200|250)/
    canon_pct = /(?:100|[1-9]?\d)/
    canon_country = /(?:10|[1-9])/
    # Up to MAX_EXCLUDED_GENRES slugs. The cap lives here as well as in
    # GlobalCanonParams so an over-long list never reaches the app at all.
    canon_genres = /[a-z0-9-]+(?:,[a-z0-9-]+){0,5}/

    get "global-canon/settings", to: "books/global_canon#settings", as: :books_global_canon_settings
    get "global-canon/genres", to: "books/global_canon#genres", as: :books_global_canon_genres
    get "global-canon", to: "books/global_canon#show", as: :books_global_canon
    get "global-canon/total_books/:total_books",
      to: "books/global_canon#show", constraints: {total_books: canon_total}
    get "global-canon/total_books/:total_books/nonfiction/:nonfiction_percentage",
      to: "books/global_canon#show",
      constraints: {total_books: canon_total, nonfiction_percentage: canon_pct}
    get "global-canon/total_books/:total_books/nonfiction/:nonfiction_percentage/max_per_country/:max_books_per_country",
      to: "books/global_canon#show",
      constraints: {total_books: canon_total, nonfiction_percentage: canon_pct, max_books_per_country: canon_country}
    get "global-canon/total_books/:total_books/nonfiction/:nonfiction_percentage/max_per_country/:max_books_per_country/excluding/:excluded_genres",
      to: "books/global_canon#show",
      constraints: {
        total_books: canon_total, nonfiction_percentage: canon_pct,
        max_books_per_country: canon_country, excluded_genres: canon_genres
      }

    # Legacy browse grammar, ported verbatim so no /genres or /countries URL needs
    # a redirect: BrowseController already reads params[:filter] and params[:sort],
    # and route segments populate params exactly as query parameters do. Only the
    # bare forms are named -- Books::BrowsePath builds every parameterised path,
    # mirroring Books::FilterPath.
    #
    # The sort and filter constraints are LOAD-BEARING, not cosmetic:
    # BrowseQuery.normalized_* falls back to the default for any input, so an
    # unconstrained segment would turn /genres/sorted-by/<anything> into an
    # unbounded space of indexable soft-duplicates. Anchors (\A, \z, ^, $) raise
    # ArgumentError in a segment constraint -- Rails anchors them itself.
    browse_sort = /(?:book_count|name)/
    browse_filter = /(?:genre|location|subject)/

    get "genres", to: "books/browse#genres", as: :books_genres
    get "genres/page/:page", to: "books/browse#genres", as: :books_genres_page,
      constraints: {page: /\d+/}
    get "genres/sorted-by/:sort", to: "books/browse#genres",
      constraints: {sort: browse_sort}
    get "genres/sorted-by/:sort/page/:page", to: "books/browse#genres",
      constraints: {sort: browse_sort, page: /\d+/}
    get "genres/filtered-by/:filter", to: "books/browse#genres",
      constraints: {filter: browse_filter}
    get "genres/filtered-by/:filter/page/:page", to: "books/browse#genres",
      constraints: {filter: browse_filter, page: /\d+/}
    get "genres/filtered-by/:filter/sorted-by/:sort", to: "books/browse#genres",
      constraints: {filter: browse_filter, sort: browse_sort}
    get "genres/filtered-by/:filter/sorted-by/:sort/page/:page", to: "books/browse#genres",
      constraints: {filter: browse_filter, sort: browse_sort, page: /\d+/}

    # MUST stay last of the /genres routes: it matches any single segment, so every
    # path above has to be declared first to win. /genres/page resolves the real
    # location category named "Page"; /genres/page/2 stays pagination.
    get "genres/:id", to: "books/legacy_categories#show"

    get "countries", to: "books/browse#countries", as: :books_countries
    get "countries/page/:page", to: "books/browse#countries", as: :books_countries_page,
      constraints: {page: /\d+/}
    get "countries/sorted-by/:sort", to: "books/browse#countries",
      constraints: {sort: browse_sort}
    get "countries/sorted-by/:sort/page/:page", to: "books/browse#countries",
      constraints: {sort: browse_sort, page: /\d+/}

    # Legacy filter grammar, ported verbatim so no filter URL needs a redirect.
    # 4 bases x 5 date forms x page x rc prefix = 80 routes, all unnamed --
    # Books::FilterPath builds these paths, so no url helper is needed, and the
    # rc prefix is spelled out rather than wrapped in a scope (a constraints:
    # inside scope "(/rc/...)" binds the positional arg to the rc segment).
    filter_bases = [
      "the-greatest-books",
      "the-greatest-books/written-by/:country_id/authors",
      "the-greatest/:category_id/books",
      "the-greatest/:category_id/books/written-by/:country_id/authors"
    ]
    filter_dates = [
      "",
      "/of/:year",
      "/since/:published_start",
      "/to/:published_end",
      "/from/:published_start/to/:published_end"
    ]

    ["", "rc/:ranking_configuration_id/"].each do |rc_prefix|
      filter_bases.each do |base|
        filter_dates.each do |date|
          get "#{rc_prefix}#{base}#{date}", to: "books/ranked_items#index"
          get "#{rc_prefix}#{base}#{date}/page/:page", to: "books/ranked_items#index",
            constraints: {page: /\d+/}
        end
      end
    end

    # Curated collections (the legacy Lists nav menu). One constrained
    # :collection segment rather than six copies of the grammar. The regex union
    # is LOAD-BEARING: an unconstrained :collection would match any single
    # segment and mint an unbounded space of indexable soft-duplicates.
    # Read straight from the registry -- no duplicated literal, so drift is
    # impossible. Autoloading from routes.rb is already proven safe in this app:
    # DomainConstraint lives in app/lib and is referenced at the top of this file.
    collection_re = Regexp.union(Collections::Registry.slugs(:books))
    collection_bases = ["the-greatest-books", "the-greatest/:category_id/books"]

    ["", "rc/:ranking_configuration_id/"].each do |rc_prefix|
      get "#{rc_prefix}:collection", to: "books/ranked_items#index",
        constraints: {collection: collection_re}
      get "#{rc_prefix}:collection/page/:page", to: "books/ranked_items#index",
        constraints: {collection: collection_re, page: /\d+/}

      collection_bases.each do |base|
        filter_dates.each do |date|
          # The bare the-greatest-books form is the canonical slug's duplicate.
          next if base == "the-greatest-books" && date == ""

          get "#{rc_prefix}:collection/#{base}#{date}", to: "books/ranked_items#index",
            constraints: {collection: collection_re}
          get "#{rc_prefix}:collection/#{base}#{date}/page/:page", to: "books/ranked_items#index",
            constraints: {collection: collection_re, page: /\d+/}
        end
      end
    end

    # Legacy duplicates of the canonical bare slug.
    get ":collection/the-greatest-books", to: redirect("/%{collection}", status: 301),
      constraints: {collection: collection_re}
    # Legacy never declared this paginated form -- only `the-greatest/books/page/:page`
    # below and the dated variants carried a page. It is kept lossless anyway: a
    # redirect that silently drops :page is worse than one that preserves it, and
    # the target routes either way.
    get ":collection/the-greatest-books/page/:page", to: redirect("/%{collection}/page/%{page}", status: 301),
      constraints: {collection: collection_re, page: /\d+/}
    get ":collection/the-greatest/books", to: redirect("/%{collection}", status: 301),
      constraints: {collection: collection_re}
    get ":collection/the-greatest/books/page/:page", to: redirect("/%{collection}/page/%{page}", status: 301),
      constraints: {collection: collection_re, page: /\d+/}
    get "v/:view_type/:collection", to: redirect("/%{collection}", status: 301),
      constraints: {collection: collection_re}
    get "v/:view_type/:collection/*rest", to: redirect("/%{collection}", status: 301),
      constraints: {collection: collection_re}
  end

  constraints DomainConstraint.new(Rails.application.config.domains[:games]) do
    # Admin interface for games domain
    namespace :admin, module: "admin/games", as: "admin_games" do
      root to: "dashboard#index"

      resources :news_topics
      resources :news_posts do
        collection do
          post :preview
        end
      end

      resources :games do
        resources :game_companies, only: [:create], shallow: true
        resources :game_platforms, only: [:create], shallow: true
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        member do
          post :execute_action
        end
        collection do
          post :import_from_igdb
          get :igdb_search
          get :search
        end
      end

      resources :game_companies, only: [:update, :destroy]
      resources :game_platforms, only: [:destroy]

      resources :companies do
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        collection do
          get :search
        end
      end

      resources :platforms do
        collection do
          get :search
        end
      end

      resources :series do
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        collection do
          get :search
        end
      end

      resources :categories do
        collection do
          get :search
        end
      end

      resources :lists do
        resource :wizard, only: [:show], controller: "list_wizard" do
          get "step/:step", action: :show_step, as: :step
          get "step/:step/status", action: :step_status, as: :step_status
          post "step/:step/advance", action: :advance_step, as: :advance_step
          post "step/:step/back", action: :back_step, as: :back_step
          post "save_html", action: :save_html, as: :save_html
          post "reparse", action: :reparse, as: :reparse
          post "restart", action: :restart
          get "igdb_game_search", to: "list_items_actions#igdb_game_search", as: :igdb_game_search
        end

        resources :items, controller: "list_items_actions", only: [] do
          member do
            get "modal/:modal_type", action: :modal, as: :modal
            post :verify
            post :skip
            patch :metadata
            post :re_enrich
            post :manual_link
            post :link_igdb_game
            post :queue_import
            delete :destroy
          end

          collection do
            post :bulk_verify
            post :bulk_skip
            delete :bulk_delete
          end
        end
      end

      resources :ranking_configurations do
        member do
          post :execute_action
        end
        collection do
          post :index_action
        end
      end

      # Shared controller, routed per domain -- same shape as descriptions and
      # category items. The domain comes from the route, so the index can scope to
      # this domain's correctable types.
      resources :corrections, only: [:index, :show], controller: "/admin/corrections" do
        member do
          post :apply
          post :reject
          post :resolve
        end
        collection do
          post :bulk_reject
        end
      end
    end

    scope as: "games" do
      get "search", to: "games/searches#index"
    end

    get "rankings", to: "games/default#rankings", as: :games_rankings

    # DELIBERATELY OUTSIDE the (/rc/:ranking_configuration_id) scope below -- see
    # the books block for the full reasoning. The short version: these pages are
    # edge-cached for a day, they show record fields rather than rankings, and an
    # unconstrained optional path segment in front of a cached page is an
    # unbounded supply of distinct cache keys, every one of them a MISS that
    # renders at origin. That is the flood that took the legacy page down.
    #
    # correctable_type comes from route defaults, never from a param: #new then
    # has no user input to validate at all. Same shared controller as books and
    # music.
    get "game/:slug/suggest-correction", to: "corrections#new",
      defaults: {correctable_type: "Games::Game"}, as: :games_game_correction,
      constraints: {format: /html/}

    # Same cacheable-GET shape as the form above, nested under the same
    # /suggest-correction prefix so robots.txt's existing
    # "Disallow: /*/suggest-correction" rule (unanchored, so it matches this
    # path too) covers it without a second rule.
    get "game/:slug/suggest-correction/thanks", to: "corrections#thanks",
      defaults: {correctable_type: "Games::Game"}, as: :games_game_correction_thanks,
      constraints: {format: /html/}

    # All games routes with optional ranking configuration parameter
    scope "(/rc/:ranking_configuration_id)" do
      get "lists/page/1", to: redirect("/lists", status: 301)
      get "lists/:id/page/1", to: redirect("/lists/%{id}", status: 301), constraints: {id: /\d+/}
      get "lists", to: "games/lists#index", as: :games_lists
      get "lists/page/:page", to: "games/lists#index", as: :games_lists_page, constraints: {page: /\d+/}
      get "lists/:id", to: "games/lists#show", as: :games_list
      get "lists/:id/page/:page", to: "games/lists#show", as: :games_list_page, constraints: {page: /\d+/}
      get "video-games", to: "games/ranked_items#index", as: :video_games
      get "video-games/page/:page", to: "games/ranked_items#index", as: :video_games_page, constraints: {page: /\d+/}
      # Year-filtered games (must come before generic patterns)
      get "video-games/since/:year", to: "games/ranked_items#index", as: :video_games_since_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "since"}
      get "video-games/since/:year/page/:page", to: "games/ranked_items#index", as: :video_games_since_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "since"}
      get "video-games/through/:year", to: "games/ranked_items#index", as: :video_games_through_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "through"}
      get "video-games/through/:year/page/:page", to: "games/ranked_items#index", as: :video_games_through_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "through"}
      get "video-games/:year", to: "games/ranked_items#index", as: :video_games_by_year,
        constraints: {year: /\d{4}(s|-\d{4})?/}
      get "video-games/:year/page/:page", to: "games/ranked_items#index", as: :video_games_by_year_page,
        constraints: {year: /\d{4}(s|-\d{4})?/, page: /\d+/}
      get "game/:slug", to: "games/games#show", as: :game

      get "categories/:id", to: "games/categories#show", as: :games_category
      get "categories/:id/page/:page", to: "games/categories#show", as: :games_category_page, constraints: {page: /\d+/}
    end

    root to: "games/ranked_items#index", as: :games_root
    get "page/:page", to: "games/ranked_items#index", as: :games_root_page, constraints: {page: /\d+/}
  end

  # Admin routes (global - no domain constraint)
  namespace :admin do
    scope "ranking_configuration/:ranking_configuration_id", as: "ranking_configuration" do
      resources :penalty_applications, only: [:index, :create]
      resources :ranked_lists, only: [:index, :create]
      resources :ranked_items, only: [:index]
    end

    resources :penalty_applications, only: [:update, :destroy]
    resources :ranked_lists, only: [:show, :destroy]

    scope "list/:list_id", as: "list" do
      resources :list_penalties, only: [:index, :create]
      resources :list_items, only: [:index, :create] do
        collection do
          delete :destroy_all
          delete :clear_positions
        end
      end
    end

    resources :list_penalties, only: [:destroy]
    resources :list_items, only: [:edit, :update, :destroy]
    resources :category_items, only: [:destroy]
    resources :images, only: [:update, :destroy], controller: "images" do
      member do
        post :set_primary
      end
    end
    resources :descriptions, only: [:update, :destroy], controller: "descriptions" do
      member do
        post :set_preferred
      end
    end
    resources :penalties
    resources :users, except: [:new, :create] do
      resources :domain_roles, only: [:index, :create, :update, :destroy]
    end

    # Billing. Global by design -- one membership covers books, music and games,
    # so these belong outside every DomainConstraint, exactly like users.
    resources :memberships, only: [:index, :show, :new, :create, :edit, :update] do
      member do
        post :revoke
        post :attach
      end
    end
    resources :donations, only: [:index]
    # `reprocess`, not `retry`: `retry` is a Ruby keyword and `def retry` is a
    # syntax error.
    resources :stripe_events, only: [:index, :show] do
      member do
        post :reprocess
      end
    end
    resources :billing_plans, only: [:index, :edit, :update]

    # Cloudflare cache management
    resource :cloudflare, only: [], controller: "cloudflare" do
      post :purge_cache
    end
  end

  # Health check
  get "up" => "rails/health#show", :as => :rails_health_check

  # Custom direct route for serving images via CDN
  # Uses Current.domain to serve images from the correct domain-specific CDN
  direct :rails_public_blob do |blob|
    domain = Current.domain || :music
    settings = Rails.application.config.domain_settings[domain]
    cdn = settings&.dig(:images_cdn)

    host = if Rails.env.production?
      cdn&.fetch(:production)
    else
      cdn&.fetch(:default)
    end

    host ||= "https://images-dev.thegreatestmusic.org"
    File.join(host, blob.key)
  end
end
