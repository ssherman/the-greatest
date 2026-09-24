# frozen_string_literal: true

module DataImporters
  # Every finder the audit pages can show, keyed by the class name stored in
  # match_decisions.finder. An entry says which admin domain owns the finder,
  # which model it resolves, how that model is merged (the Actions::Admin::*
  # action name, the field that action reads the source id from, and the
  # record's execute_action route), what to preload for a summary, and whether
  # the finder's real sources have landed (recheck). A finder with no entry
  # never reaches an audit page: the decisions index filters by the domain's
  # registered finder names and the duplicates index by its registered models.
  module FinderRegistry
    URL_HELPERS = Rails.application.routes.url_helpers

    Entry = Struct.new(
      :finder, :domain, :model, :label, :query, :preloads,
      :merge_action, :source_field, :execute_action_path, :recheck,
      keyword_init: true
    ) do
      def finder_class = finder.constantize

      def model_class = model.constantize

      def query_class = query.constantize

      def mergeable? = merge_action.present?

      def recheck? = recheck == true
    end

    ENTRIES = [
      Entry.new(
        finder: "DataImporters::Books::Book::Finder", domain: :books, model: "Books::Book", label: "Book",
        query: "DataImporters::Books::Book::ImportQuery", preloads: [:authors],
        merge_action: "MergeBook", source_field: "source_book_id",
        execute_action_path: ->(record) { URL_HELPERS.execute_action_admin_books_book_path(record) },
        recheck: true
      ),
      Entry.new(
        finder: "DataImporters::Games::Game::Finder", domain: :games, model: "Games::Game", label: "Game",
        query: "DataImporters::Games::Game::ImportQuery", preloads: [:companies],
        merge_action: "MergeGame", source_field: "source_game_id",
        execute_action_path: ->(record) { URL_HELPERS.execute_action_admin_games_game_path(record) },
        recheck: false
      ),
      Entry.new(
        finder: "DataImporters::Games::Company::Finder", domain: :games, model: "Games::Company", label: "Company",
        query: "DataImporters::Games::Company::ImportQuery", preloads: [],
        merge_action: nil, source_field: nil, execute_action_path: nil,
        recheck: false
      ),
      Entry.new(
        finder: "DataImporters::Music::Artist::Finder", domain: :music, model: "Music::Artist", label: "Artist",
        query: "DataImporters::Music::Artist::ImportQuery", preloads: [],
        merge_action: "MergeArtist", source_field: "source_artist_id",
        execute_action_path: ->(record) { URL_HELPERS.execute_action_admin_artist_path(record) },
        recheck: false
      ),
      Entry.new(
        finder: "DataImporters::Music::Album::Finder", domain: :music, model: "Music::Album", label: "Album",
        query: "DataImporters::Music::Album::ImportQuery", preloads: [:artists],
        merge_action: "MergeAlbum", source_field: "source_album_id",
        execute_action_path: ->(record) { URL_HELPERS.execute_action_admin_album_path(record) },
        recheck: false
      ),
      Entry.new(
        finder: "DataImporters::Music::Song::Finder", domain: :music, model: "Music::Song", label: "Song",
        query: "DataImporters::Music::Song::ImportQuery", preloads: [:artists],
        merge_action: "MergeSong", source_field: "source_song_id",
        execute_action_path: ->(record) { URL_HELPERS.execute_action_admin_song_path(record) },
        recheck: false
      )
    ].freeze

    BY_FINDER = ENTRIES.index_by(&:finder).freeze
    BY_MODEL = ENTRIES.index_by(&:model).freeze

    class << self
      def entry(finder_name) = BY_FINDER[finder_name.to_s]

      def entry_for_model(model_name) = BY_MODEL[model_name.to_s]

      def for_domain(domain) = ENTRIES.select { |entry| entry.domain == domain.to_sym }

      def finders_for(domain) = for_domain(domain).map(&:finder)

      def models_for(domain) = for_domain(domain).map(&:model)
    end
  end
end
